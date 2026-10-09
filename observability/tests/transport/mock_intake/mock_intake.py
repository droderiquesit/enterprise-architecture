"""Minimal mock of the Datadog logs intake used by the local transport tests.

POST /api/v2/logs          -> records the (optionally gzip-compressed) JSON array, returns 202
GET  /_received            -> every event received so far (flattened list), plus request metadata
DELETE /_received          -> reset
GET  /healthz              -> 200

Synthetic data only. Never point a real Fluent Bit at this with a real API key.
"""

import gzip
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()
_events: list[dict] = []
_requests: list[dict] = []


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-dd-intake/1.0"

    def log_message(self, fmt, *args):  # keep container logs quiet
        return

    def _send(self, code: int, body: object) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        if self.path == "/_received":
            with _lock:
                return self._send(200, {"events": list(_events), "requests": list(_requests)})
        return self._send(404, {"error": "not found"})

    def do_DELETE(self):  # noqa: N802
        if self.path == "/_received":
            with _lock:
                _events.clear()
                _requests.clear()
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        encoding = (self.headers.get("Content-Encoding") or "").lower()
        if encoding == "gzip":
            raw = gzip.decompress(raw)
        if self.path.split("?")[0] != "/api/v2/logs":
            return self._send(404, {"error": "unknown path"})
        api_key = self.headers.get("DD-API-KEY") or self.headers.get("dd-api-key")
        if not api_key:
            return self._send(403, {"error": "missing api key"})
        try:
            body = json.loads(raw)
        except ValueError:
            return self._send(400, {"error": "invalid json"})
        items = body if isinstance(body, list) else [body]
        with _lock:
            _events.extend(items)
            _requests.append(
                {
                    "path": self.path,
                    "content_encoding": encoding,
                    "content_type": self.headers.get("Content-Type"),
                    "count": len(items),
                    "api_key_present": True,
                }
            )
        return self._send(202, {})


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
