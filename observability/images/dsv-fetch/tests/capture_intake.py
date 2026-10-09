"""Header-capturing fake Datadog intake for the dsv-fetch docker smoke test (stdlib). Records, per request, the path and
the SHA-256 of the DD-API-KEY header (never the key itself), so a test can prove which key a consumer actually used.

    POST <any>      -> 202 {}            (Fluent Bit logs, collector series, Agent intake/series/check_run/...)
    GET  /_received -> {"requests": [{"method","path","api_key_sha256"}]}
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()
_requests: list[dict] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, code: int, body: object) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _record(self, method: str) -> None:
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                self.rfile.read(size + 2) if size else self.rfile.readline()
                if not size:
                    break
        else:
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
        key = self.headers.get("DD-API-KEY")
        with _lock:
            _requests.append({"method": method, "path": self.path.split("?")[0], "api_key_sha256": hashlib.sha256(key.encode()).hexdigest() if key else None})

    def do_POST(self):
        self._record("POST")
        self._send(202, {})

    def do_PUT(self):
        self._record("PUT")
        self._send(202, {})

    def do_GET(self):
        if self.path == "/_received":
            with _lock:
                return self._send(200, {"requests": list(_requests)})
        # Agent/exporter API-key validation and metadata endpoints
        return self._send(200, {"valid": True})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()  # noqa: S104 - test container
