#!/usr/bin/env python3
"""Mock Delinea DevOps Secrets Vault (DSV) API for local integration tests. Not a security boundary.

Implements the subset of the DSV REST API used in this repository (see ADR-0001 section 14):

  POST /v1/token          {"grant_type": "azure", "jwt": "<entra token>"}               -> {"accessToken", "expiresIn", "tokenType"}
                          {"grant_type": "client_credentials", "client_id", "client_secret"}
  GET  /v1/secrets/<path> Authorization: Bearer <accessToken>                            -> {"id", "path", "data", "attributes", "version"}
  POST /v1/secrets/<path> {"data": {...}, "attributes": {...}}  (create)                -> secret
  PUT  /v1/secrets/<path> {"data": {...}}                       (update, version += 1)  -> secret
  GET  /v1/__calls        test helper: list of {method, path, identity} (no values)

Azure grant: the JWT is NOT verified (tests cannot mint Entra tokens). Its payload is decoded and the identity is taken
from the `xms_mirid` claim (managed identity resource id - what DSV maps to a user's external id), falling back to
`oid`. Authorization: an identity may read a path only if it matches one of its policy globs.

Config (JSON file, --config):
  {"users":   {"<external id or client_id>": {"read": ["eh/dev/*"], "write": []}},
   "clients": {"<client_id>": {"secret": "<client_secret>", "identity": "<external id>"}},
   "secrets": {"eh/dev/datadog-api-key": {"value": "test-key"}}}

Run:   python3 tools/secrets/mock_dsv.py --config cfg.json --port 8200
Use:   DSV_BASE_URL=http://127.0.0.1:8200/v1   (overrides https://<DSV_TENANT>.secretsvaultcloud.<DSV_TLD>/v1)
"""

from __future__ import annotations

import argparse
import base64
import fnmatch
import json
import secrets as _secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_TTL = 3600


def _jwt_identity(jwt: str) -> str | None:
    try:
        payload = jwt.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001 - malformed token -> unauthenticated
        return None
    return claims.get("xms_mirid") or claims.get("oid")


class State:
    def __init__(self, cfg: dict):
        self.lock = threading.Lock()
        self.users = cfg.get("users", {})
        self.clients = cfg.get("clients", {})
        self.secrets = {k.strip("/"): {"data": v, "version": 1, "attributes": {}} for k, v in cfg.get("secrets", {}).items()}
        self.tokens: dict[str, tuple[str, float]] = {}
        self.calls: list[dict] = []

    def allowed(self, identity: str, path: str, verb: str) -> bool:
        globs = self.users.get(identity, {}).get(verb, [])
        return any(fnmatch.fnmatchcase(path, g.strip("/")) for g in globs)


def make_handler(state: State):
    class Handler(BaseHTTPRequestHandler):
        server_version = "mock-dsv/1"

        def log_message(self, *_):  # quiet
            pass

        def _send(self, code: int, body: dict) -> None:
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")

        def _identity(self) -> str | None:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                return None
            tok = state.tokens.get(auth[7:])
            if not tok or tok[1] < time.time():
                return None
            return tok[0]

        def _record(self, method: str, path: str, identity: str | None) -> None:
            with state.lock:
                state.calls.append({"method": method, "path": path, "identity": identity})

        def do_POST(self):  # noqa: N802
            if self.path == "/v1/token":
                body = self._body()
                identity = None
                if body.get("grant_type") == "azure":
                    identity = _jwt_identity(body.get("jwt", ""))
                elif body.get("grant_type") == "client_credentials":
                    c = state.clients.get(body.get("client_id", ""))
                    if c and _secrets.compare_digest(c.get("secret", ""), body.get("client_secret", "")):
                        identity = c.get("identity") or body["client_id"]
                if not identity or identity not in state.users:
                    self._record("POST", "/v1/token", identity)
                    return self._send(401, {"code": 401, "message": "unauthorized"})
                token = _secrets.token_urlsafe(24)
                state.tokens[token] = (identity, time.time() + TOKEN_TTL)
                self._record("POST", "/v1/token", identity)
                return self._send(200, {"accessToken": token, "tokenType": "bearer", "expiresIn": TOKEN_TTL})
            return self._write("POST")

        def do_PUT(self):  # noqa: N802
            return self._write("PUT")

        def _write(self, method: str):
            if not self.path.startswith("/v1/secrets/"):
                return self._send(404, {"message": "not found"})
            path = self.path[len("/v1/secrets/"):].strip("/")
            identity = self._identity()
            self._record(method, path, identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            if not state.allowed(identity, path, "write"):
                return self._send(403, {"message": "forbidden"})
            body = self._body()
            with state.lock:
                cur = state.secrets.get(path)
                if method == "POST" and cur:
                    return self._send(400, {"message": "secret already exists"})
                if method == "PUT" and not cur:
                    return self._send(404, {"message": "not found"})
                version = (cur["version"] + 1) if cur else 1
                state.secrets[path] = {"data": body.get("data", {}), "attributes": body.get("attributes", {}), "version": version}
            return self._send(200, self._secret(path))

        def _secret(self, path: str) -> dict:
            s = state.secrets[path]
            return {"id": path, "path": path, "data": s["data"], "attributes": s["attributes"], "version": str(s["version"])}

        def do_GET(self):  # noqa: N802
            if self.path == "/v1/__calls":
                with state.lock:
                    return self._send(200, {"calls": list(state.calls)})
            if not self.path.startswith("/v1/secrets/"):
                return self._send(404, {"message": "not found"})
            path = self.path[len("/v1/secrets/"):].strip("/")
            identity = self._identity()
            self._record("GET", path, identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            if not state.allowed(identity, path, "read"):
                return self._send(403, {"message": "forbidden"})
            if path not in state.secrets:
                return self._send(404, {"message": "not found"})
            return self._send(200, self._secret(path))

    return Handler


def serve(cfg: dict, host: str = "127.0.0.1", port: int = 0) -> tuple[ThreadingHTTPServer, State]:
    """Start in a background thread; returns (server, state). server.server_address[1] is the bound port."""
    state = State(cfg)
    httpd = ThreadingHTTPServer((host, port), make_handler(state))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, state


def fake_entra_token(mirid: str) -> str:
    """Unsigned JWT-shaped token carrying `xms_mirid` - for tests only."""
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")  # noqa: E731
    return f"{enc({'alg': 'none', 'typ': 'JWT'})}.{enc({'xms_mirid': mirid, 'aud': 'https://management.azure.com/'})}.sig"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8200)
    a = ap.parse_args()
    with open(a.config) as fh:
        cfg = json.load(fh)
    httpd, _ = serve(cfg, a.host, a.port)
    print(f"mock DSV listening on http://{a.host}:{httpd.server_address[1]}/v1", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        httpd.shutdown()


if __name__ == "__main__":
    main()
