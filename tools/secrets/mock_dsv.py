#!/usr/bin/env python3
"""Mock Delinea DevOps Secrets Vault (DSV) API for local integration tests. Not a security boundary.

Implements the subset of the DSV REST API used in this repository (see ADR-0001 section 14):

  POST /v1/token          {"grant_type": "azure", "jwt": "<entra token>"}               -> {"accessToken", "expiresIn", "tokenType"}
                          {"grant_type": "client_credentials", "client_id", "client_secret"}
  GET  /v1/secrets/<path> Authorization: Bearer <accessToken>                            -> {"id", "path", "data", "attributes", "version"}
  POST /v1/secrets/<path> {"data": {...}, "attributes": {...}}  (create)                -> secret
  PUT  /v1/secrets/<path> {"data": {...}}                       (update, version += 1)  -> secret
  GET  /v1/secrets/<path>::description   metadata only (no data); needs read or list
  GET  /v1/secrets?searchTerm=<prefix>   list paths (needs list on the matching paths)
  GET  /v1/__calls        test helper: list of {method, path, identity} (no values)

Admin subset (dsv-cli v1.41.1 commands/auth_provider.go, user.go, policy.go) used by tools/secrets/dsv_apply.py;
callers need `"admin": true` in their config entry:
  GET|PUT /v1/config/auth/<name>   POST /v1/config/auth/      {name, type, properties: {tenantId}}
  GET|PUT /v1/users/<name>         POST /v1/users/            {userName, displayName, provider, externalId}
                                   GET /v1/users?searchTerm=   ("<provider>:<userName>" addresses federated users)
  GET|PUT /v1/config/policies/<p>  POST /v1/config/policies/  {path, policy: "<json permissionDocument>", serialization}
API-created users authenticate with the azure grant when the token's xms_mirid equals their externalId, and are
authorized by the permissions of API-created policies (subjects users:<provider:name>, resources secrets:a:b:c, DSV
`<regex>` segments, actions read/create/update/list) - so dsv_apply + workload reads can be tested end-to-end.

Azure grant: the JWT is NOT verified (tests cannot mint Entra tokens). Its payload is decoded and the identity is taken
from the `xms_mirid` claim (managed identity resource id - what DSV maps to a user's external id), falling back to
`oid`. Authorization: an identity may read a path only if it matches one of its policy globs.

Config (JSON file, --config):
  {"users":   {"<external id or client_id>": {"read": ["eh/dev/*"], "write": [], "list": [], "admin": false}},
   "auth_providers": {"azure-eh": {"type": "azure", "properties": {"tenantId": "..."}}},
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
import re
import secrets as _secrets
import urllib.parse
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
        # admin objects (DSV config); keys: provider name / qualified user name / policy path (colon form)
        self.auth_providers: dict[str, dict] = {k: {"name": k, **v} for k, v in cfg.get("auth_providers", {}).items()}
        self.dsv_users: dict[str, dict] = {}
        self.policies: dict[str, dict] = {}

    # ------------------------------------------------------------ identities
    def known(self, identity: str | None) -> bool:
        return bool(identity) and (identity in self.users or self.api_user(identity) is not None)

    def api_user(self, identity: str) -> dict | None:
        for u in self.dsv_users.values():
            if u.get("externalId") and u["externalId"].lower() == identity.lower():
                return u
        return None

    def is_admin(self, identity: str | None) -> bool:
        return bool(identity) and bool(self.users.get(identity, {}).get("admin"))

    # ------------------------------------------------------------ authorization
    def allowed(self, identity: str, path: str, verb: str) -> bool:
        if self.is_admin(identity):
            return True
        globs = self.users.get(identity, {}).get("write" if verb in ("create", "update") else verb, [])
        if any(fnmatch.fnmatchcase(path, g.strip("/")) for g in globs):
            return True
        user = self.api_user(identity)
        if user is None:
            return False
        subject = f"users:{user['provider']}:{user['userName']}" if user.get("provider") else f"users:{user['userName']}"
        actions = {"read": {"read"}, "write": {"create", "update"}, "create": {"create"}, "update": {"update"},
                   "list": {"list"}}.get(verb, {verb})
        resource = "secrets:" + path.strip("/").replace("/", ":")
        verdict = False
        for pol in self.policies.values():
            for perm in pol.get("permissionDocument", []):
                if not set(perm.get("actions", [])) & actions and "<.*>" not in perm.get("actions", []):
                    continue
                if not any(_dsv_match(s, subject) for s in perm.get("subjects", [])):
                    continue
                if not any(_dsv_match(r, resource) for r in perm.get("resources", [])):
                    continue
                if perm.get("effect", "allow") == "deny":
                    return False
                verdict = True
        return verdict


def _dsv_match(pattern: str, value: str) -> bool:
    """DSV policy matching: literal text, with `<regex>` segments (e.g. users:<azure-eh:eh-dev-x>, secrets:eh:<.*>)."""
    rx = ""
    for part in re.split(r"(<[^>]*>)", pattern):
        rx += part[1:-1] if part.startswith("<") and part.endswith(">") else re.escape(part)
    return re.fullmatch(rx, value) is not None


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
            if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
                raw = b""
                while True:
                    size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        self.rfile.readline()  # trailing CRLF after the last chunk
                        break
                    raw += self.rfile.read(size)
                    self.rfile.readline()
                return json.loads(raw or b"{}")
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
                if not state.known(identity):
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
            if self.path.startswith(("/v1/config/", "/v1/users")):
                return self._admin(method)
            if not self.path.startswith("/v1/secrets/"):
                return self._send(404, {"message": "not found"})
            path = self.path[len("/v1/secrets/"):].strip("/")
            identity = self._identity()
            self._record(method, path, identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            if not state.allowed(identity, path, "create" if method == "POST" else "update"):
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

        def _search(self):
            identity = self._identity()
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            term = (q.get("searchTerm") or [""])[0].strip("/")
            self._record("GET", f"secrets?searchTerm={term}", identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            with state.lock:
                found = [p for p in sorted(state.secrets) if p.startswith(term) and state.allowed(identity, p, "list")]
            return self._send(200, {"data": [{"path": p, "version": str(state.secrets[p]["version"])} for p in found]})

        def _admin(self, method: str):
            identity = self._identity()
            split = urllib.parse.urlsplit(self.path)
            route = urllib.parse.unquote(split.path)
            self._record(method, route, identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            if not state.is_admin(identity):
                return self._send(403, {"message": "forbidden"})
            for prefix, store, key_of in (("/v1/config/auth", state.auth_providers, lambda b: b.get("name")),
                                          ("/v1/users", state.dsv_users, _qualified),
                                          ("/v1/config/policies", state.policies, lambda b: (b.get("path") or "").replace("/", ":"))):
                if route == prefix or route.startswith(prefix + "/"):
                    name = route[len(prefix):].strip("/")
                    return self._crud(method, store, name, key_of, split.query)
            return self._send(404, {"message": "not found"})

        def _crud(self, method: str, store: dict, name: str, key_of, query: str):
            with state.lock:
                if method == "GET" and not name:
                    term = (urllib.parse.parse_qs(query).get("searchTerm") or [""])[0]
                    return self._send(200, {"data": [_public(v) for k, v in sorted(store.items()) if term in k]})
                if method == "GET":
                    obj = store.get(name)
                    return self._send(200, _public(obj)) if obj else self._send(404, {"code": 404, "message": "not found"})
                body = self._body()
                if method == "POST":
                    if name:
                        return self._send(405, {"message": "method not allowed"})
                    key = key_of(body)
                    if not key:
                        return self._send(400, {"message": "missing name"})
                    if key in store:
                        return self._send(400, {"code": 400, "message": "a security principal with this name already exists"})
                    store[key] = _normalize(body, version=0)
                    return self._send(200, _public(store[key]))
                if method == "PUT":
                    if name not in store:
                        return self._send(404, {"code": 404, "message": "not found"})
                    cur = store[name]
                    if "userName" in cur and set(body) - {"displayName", "displayname", "password"}:
                        return self._send(400, {"message": "only password/displayName can be updated"})
                    merged = {**cur, **_normalize(body, version=int(cur.get("version", 0)) + 1)}
                    if "displayname" in body:
                        merged["displayName"] = body["displayname"]
                    store[name] = merged
                    return self._send(200, _public(merged))
            return self._send(405, {"message": "method not allowed"})

        def do_GET(self):  # noqa: N802
            if self.path == "/v1/__calls":
                with state.lock:
                    return self._send(200, {"calls": list(state.calls)})
            if self.path.startswith(("/v1/config/", "/v1/users")):
                return self._admin("GET")
            if self.path.startswith("/v1/secrets?"):
                return self._search()
            if not self.path.startswith("/v1/secrets/"):
                return self._send(404, {"message": "not found"})
            path = self.path[len("/v1/secrets/"):].strip("/")
            describe = path.endswith("::description")
            path = path[: -len("::description")] if describe else path
            identity = self._identity()
            self._record("GET", path, identity)
            if identity is None:
                return self._send(401, {"message": "unauthorized"})
            if describe:
                if not (state.allowed(identity, path, "read") or state.allowed(identity, path, "list")):
                    return self._send(403, {"message": "forbidden"})
                if path not in state.secrets:
                    return self._send(404, {"message": "not found"})
                s = state.secrets[path]
                return self._send(200, {"id": path, "path": path, "attributes": s["attributes"], "version": str(s["version"])})
            if not state.allowed(identity, path, "read"):
                return self._send(403, {"message": "forbidden"})
            if path not in state.secrets:
                return self._send(404, {"message": "not found"})
            return self._send(200, self._secret(path))

    return Handler


def _qualified(body: dict) -> str:
    return f"{body['provider']}:{body.get('userName')}" if body.get("provider") else (body.get("userName") or "")


def _normalize(body: dict, version: int) -> dict:
    out = {k: v for k, v in body.items() if k not in ("password", "displayname")}
    if "policy" in out:  # stored parsed, like DSV returns it
        out.update(json.loads(out.pop("policy")))
        out.pop("serialization", None)
    out["version"] = str(version)
    return out


def _public(obj: dict | None) -> dict | None:
    return None if obj is None else {k: v for k, v in obj.items() if k != "password"}


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
