"""Minimal mock of the Datadog logs intake used by the local transport tests.

POST /api/v2/logs          -> records the (optionally gzip-compressed) JSON array, returns 202
POST anything else         -> recorded as an "other" request (path, size, headers) and answered 202, so the
                              Datadog exporter of an OTel collector can be pointed here (traces/metrics/series)
GET  /_received            -> every log event received so far (flattened list), plus request metadata
DELETE /_received          -> reset
GET  /healthz              -> 200

Synthetic data only. Never point a real Fluent Bit at this with a real API key.
"""

import gzip
import hashlib
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()
_events: list[dict] = []
_requests: list[dict] = []
_others: list[dict] = []


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
                return self._send(200, {"events": list(_events), "requests": list(_requests), "others": list(_others)})
        return self._send(404, {"error": "not found"})

    def do_DELETE(self):  # noqa: N802
        if self.path == "/_received":
            with _lock:
                _events.clear()
                _requests.clear()
                _others.clear()
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def _read_chunked(self) -> bytes:
        data = b""
        while True:
            size = int(self.rfile.readline().strip().split(b";")[0], 16)
            if size == 0:
                self.rfile.readline()
                return data
            data += self.rfile.read(size)
            self.rfile.readline()

    def do_POST(self):  # noqa: N802
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            raw = self._read_chunked()
        else:
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        encoding = (self.headers.get("Content-Encoding") or "").lower()
        if encoding == "gzip":
            try:
                raw = gzip.decompress(raw)
            except OSError:
                return self._send(400, {"error": "bad gzip"})
        api_key = self.headers.get("DD-API-KEY") or self.headers.get("dd-api-key")
        if self.path.split("?")[0] != "/api/v2/logs":
            with _lock:
                _others.append(
                    {
                        "path": self.path.split("?")[0],
                        "bytes": len(raw),
                        "content_type": self.headers.get("Content-Type"),
                        "api_key_present": bool(api_key),
                        # sha256 only (never the value): proves which key arrived (DSV -> dsv-fetch -> collector)
                        "api_key_sha256": hashlib.sha256(api_key.encode()).hexdigest() if api_key else None,
                    }
                )
            return self._send(202, {})
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
                    "api_key_sha256": hashlib.sha256(api_key.encode()).hexdigest(),
                }
            )
        return self._send(202, {})


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
