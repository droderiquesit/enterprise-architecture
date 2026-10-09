"""Fake Azure identity endpoints for tests (stdlib): IMDS (/metadata/identity/oauth2/token, needs `Metadata: true`),
App Service / Container Apps IDENTITY_ENDPOINT (/msi/token, needs `X-IDENTITY-HEADER: identity-header-secret`) and the
Entra token endpoint for workload-identity client assertions (/<tenant>/oauth2/v2.0/token, assertion
`federated-sa-token`). Tokens are unsigned JWTs carrying `xms_mirid` (what DSV maps to a user's external id).

    python3 fake_identity.py --mirid <identity resource id> [--host 0.0.0.0] [--port 8300]
"""

from __future__ import annotations

import argparse
import base64
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def fake_entra_token(mirid: str) -> str:
    def enc(d: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")

    return f"{enc({'alg': 'none', 'typ': 'JWT'})}.{enc({'xms_mirid': mirid, 'aud': 'https://management.azure.com/'})}.sig"


class IdentityServer:
    """IMDS (/metadata/identity/oauth2/token), App Service/ACA IDENTITY_ENDPOINT (/msi/token) and Entra (/<tenant>/oauth2/v2.0/token)."""

    def __init__(self, mirid: str, imds_failures: int = 0, host: str = "127.0.0.1", port: int = 0) -> None:
        self.mirid = mirid
        self.requests: list[dict] = []
        self.imds_failures = imds_failures
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def _reply(self, code: int, doc: dict) -> None:
                raw = json.dumps(doc).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _token(self) -> None:
                self._reply(200, {"access_token": fake_entra_token(outer.mirid), "expires_on": "9999999999", "resource": "https://management.azure.com/"})

            def do_GET(self):
                url = urllib.parse.urlsplit(self.path)
                q = dict(urllib.parse.parse_qsl(url.query))
                outer.requests.append({"method": "GET", "path": url.path, "query": q, "headers": dict(self.headers)})
                if url.path == "/metadata/identity/oauth2/token":
                    if self.headers.get("Metadata") != "true":
                        return self._reply(400, {"error": "missing Metadata header"})
                    if outer.imds_failures > 0:
                        outer.imds_failures -= 1
                        return self._reply(503, {"error": "busy"})
                    return self._token()
                if url.path == "/msi/token":
                    if self.headers.get("X-IDENTITY-HEADER") != "identity-header-secret":
                        return self._reply(401, {"error": "bad header"})
                    return self._token()
                return self._reply(404, {"error": "not found"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                form = dict(urllib.parse.parse_qsl(self.rfile.read(n).decode()))
                outer.requests.append({"method": "POST", "path": self.path, "form": form, "headers": dict(self.headers)})
                if self.path.endswith("/oauth2/v2.0/token") and form.get("client_assertion") == "federated-sa-token":
                    return self._token()
                return self._reply(401, {"error": "invalid_client"})

        self.httpd = ThreadingHTTPServer((host, port), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirid", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8300)
    a = ap.parse_args()
    srv = IdentityServer(a.mirid, host=a.host, port=a.port)
    print(f"fake identity listening on {srv.url}", flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
