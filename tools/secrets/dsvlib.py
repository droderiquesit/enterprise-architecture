"""Minimal Delinea DevOps Secrets Vault (DSV) REST client shared by tools/secrets/* (stdlib only).

Protocol (ADR-0001 section 14; Delinea dsv-sdk-go v2.3.0 auth/azure.go, vault/vault.go; dsv-cli v1.41.1 commands/*):
  POST {base}/token                       {"grant_type": "azure", "jwt": <Entra token for https://management.azure.com/>}
                                          {"grant_type": "client_credentials", "client_id", "client_secret"}  (local/test)
  GET  {base}/secrets/<path>              -> {"id", "path", "data": {...}, "attributes", "version"}
  GET  {base}/secrets/<path>::description -> metadata without data (dsv-cli `secret describe`)
  POST {base}/secrets/<path>  PUT ...     create / update {"data": {...}}
  admin (dsv-cli commands/auth_provider.go, user.go, policy.go):
  GET|PUT {base}/config/auth/<name>, POST {base}/config/auth/       auth providers {name, type, properties{tenantId}}
  GET|PUT {base}/users/<name>,       POST {base}/users/             users {userName, displayName, provider, externalId}
  GET|PUT {base}/config/policies/<path>, POST {base}/config/policies/  {path, policy: <json permissionDocument>, serialization: json}

Configuration (environment, all optional except the tenant):
  DSV_AUTH = azure (default) | client_credentials (DSV_CLIENT_ID, DSV_CLIENT_SECRET) | none
  DSV_TENANT, DSV_TLD (default com), DSV_BASE_URL (override, e.g. http://127.0.0.1:<port>/v1 for tools/secrets/mock_dsv.py)
  AZURE_CLIENT_ID (user-assigned identity client id; required when the host has several identities)
  IDENTITY_ENDPOINT + IDENTITY_HEADER (App Service / Functions / Container Apps) else IMDS (DSV_IMDS_ENDPOINT overrides
  http://169.254.169.254 for tests), DSV_TIMEOUT_SECONDS (default 5).
Secret VALUES never appear in exceptions, logs or return values other than get_value()/read().
"""

from __future__ import annotations

import json
import os
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional, Tuple

ARM_RESOURCE = "https://management.azure.com/"
REF_PREFIX = "dsv://"
RETRY_STATUS = (429, 500, 502, 503, 504)


class DsvError(Exception):
    """Errors name paths/operations only, never values."""

    def __init__(self, message: str, status: Optional[int] = None):
        super().__init__(message)
        self.status = status


def parse_ref(ref: str) -> Tuple[str, str]:
    """dsv://<path>#<element> -> (path, element); element defaults to `value`."""
    if not ref.startswith(REF_PREFIX):
        raise DsvError(f"not a DSV reference (expected {REF_PREFIX}<path>#<element>)")
    rest = ref[len(REF_PREFIX):]
    path, _, element = rest.partition("#")
    path = path.strip("/")
    if not path or ".." in path.split("/"):
        raise DsvError("invalid DSV reference path")
    return path, element or "value"


def secret_spec(base_path: str, spec: str) -> Tuple[str, str, bool]:
    """Registry secret_env value `<name>[#element][?]` or a full dsv:// ref -> (path, element, optional)."""
    optional = spec.endswith("?")
    spec = spec.rstrip("?")
    if spec.startswith(REF_PREFIX):
        path, element = parse_ref(spec)
        return path, element, optional
    name, _, element = spec.partition("#")
    return f"{base_path.strip('/')}/{name}", element or "value", optional


def load_env_settings(repo: Path, env: str) -> dict:
    """`environment` + `secrets` sections of environments/<env>/environment.yaml (identifiers only)."""
    import yaml

    doc = yaml.safe_load((repo / "environments" / env / "environment.yaml").read_text()) or {}
    sec = dict(doc.get("secrets") or {})
    envd = doc.get("environment") or {}
    sec.setdefault("tld", "com")
    sec["base_path"] = f"{envd.get('name_prefix', 'eh')}/{envd.get('name', env)}"
    sec["tenant_id"] = envd.get("tenant_id")
    return sec


def base_url_from(settings: Optional[dict] = None) -> str:
    settings = settings or {}
    explicit = os.environ.get("DSV_BASE_URL") or settings.get("base_url")
    if explicit:
        return explicit.rstrip("/")
    tenant = os.environ.get("DSV_TENANT") or settings.get("tenant")
    tld = os.environ.get("DSV_TLD") or settings.get("tld") or "com"
    if not tenant:
        raise DsvError("DSV tenant unknown: set DSV_TENANT / DSV_BASE_URL or environments/<env>/environment.yaml secrets.tenant")
    return f"https://{tenant}.secretsvaultcloud.{tld}/v1"


def _http(method: str, url: str, body=None, headers: Optional[dict] = None, timeout: float = 5.0):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Accept": "application/json", **(headers or {})})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - https/loopback only (base URL)
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError:
            payload = {}
        return exc.code, payload
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        raise DsvError(f"{method} {urllib.parse.urlsplit(url).path}: {type(exc).__name__}") from None


def entra_token(timeout: float = 5.0) -> str:
    """Access token for https://management.azure.com/ from the host's (user-assigned) managed identity."""
    client_id = os.environ.get("AZURE_CLIENT_ID")
    if os.environ.get("IDENTITY_ENDPOINT") and os.environ.get("IDENTITY_HEADER"):
        q = {"api-version": "2019-08-01", "resource": ARM_RESOURCE}
        if client_id:
            q["client_id"] = client_id
        url = os.environ["IDENTITY_ENDPOINT"] + "?" + urllib.parse.urlencode(q)
        status, body = _http("GET", url, headers={"X-IDENTITY-HEADER": os.environ["IDENTITY_HEADER"]}, timeout=timeout)
    else:
        q = {"api-version": "2018-02-01", "resource": ARM_RESOURCE}
        if client_id:
            q["client_id"] = client_id
        base = os.environ.get("DSV_IMDS_ENDPOINT", "http://169.254.169.254").rstrip("/")
        url = f"{base}/metadata/identity/oauth2/token?" + urllib.parse.urlencode(q)
        status, body = _http("GET", url, headers={"Metadata": "true"}, timeout=timeout)
    if status != 200 or not body.get("access_token"):
        raise DsvError(f"managed identity token request failed (HTTP {status})", status)
    return body["access_token"]


@dataclass
class _Token:
    value: str
    expires_at: float


class DsvClient:
    def __init__(self, base_url: str, auth: Optional[str] = None, timeout: Optional[float] = None, retries: int = 3):
        self.base_url = base_url.rstrip("/")
        self.auth = (auth or os.environ.get("DSV_AUTH") or "azure").lower()
        self.timeout = float(timeout or os.environ.get("DSV_TIMEOUT_SECONDS") or 5)
        self.retries = retries
        self._token: Optional[_Token] = None

    # ------------------------------------------------------------------ auth
    def _login(self) -> _Token:
        if self.auth == "azure":
            body = {"grant_type": "azure", "jwt": entra_token(self.timeout)}
        elif self.auth == "client_credentials":
            cid, secret = os.environ.get("DSV_CLIENT_ID"), os.environ.get("DSV_CLIENT_SECRET")
            if not cid or not secret:
                raise DsvError("DSV_AUTH=client_credentials needs DSV_CLIENT_ID and DSV_CLIENT_SECRET")
            body = {"grant_type": "client_credentials", "client_id": cid, "client_secret": secret}
        else:
            raise DsvError(f"DSV_AUTH={self.auth}: no DSV authentication configured")
        status, resp = _http("POST", f"{self.base_url}/token", body, timeout=self.timeout)
        if status != 200 or not resp.get("accessToken"):
            raise DsvError(f"DSV token request failed (HTTP {status})", status)
        ttl = float(resp.get("expiresIn") or 3600)
        return _Token(resp["accessToken"], time.time() + 0.8 * ttl)  # refresh at 80 % of the lifetime

    def token(self) -> str:
        if self._token is None or time.time() >= self._token.expires_at:
            self._token = self._login()
        return self._token.value

    # ------------------------------------------------------------------ requests
    def request(self, method: str, path: str, body=None, query: Optional[dict] = None):
        """(status, json) - bounded retries with jitter on 429/5xx; one re-login on 401."""
        url = f"{self.base_url}/{path.lstrip('/')}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        relogged = False
        for attempt in range(self.retries + 1):
            status, resp = _http(method, url, body, {"Authorization": f"Bearer {self.token()}"}, self.timeout)
            if status == 401 and not relogged:
                self._token, relogged = None, True
                continue
            if status in RETRY_STATUS and attempt < self.retries:
                time.sleep(min(4.0, 0.25 * 2 ** attempt) + random.uniform(0, 0.2))  # noqa: S311 - jitter
                continue
            return status, resp
        return status, resp

    # ------------------------------------------------------------------ secrets
    def read(self, path: str) -> dict:
        status, resp = self.request("GET", f"secrets/{path.strip('/')}")
        if status != 200:
            raise DsvError(f"read secrets/{path}: HTTP {status}", status)
        return resp

    def get_value(self, ref: str) -> str:
        path, element = parse_ref(ref)
        data = self.read(path).get("data") or {}
        if element not in data:
            raise DsvError(f"secret {path} has no element '{element}'")
        value = data[element]
        return value if isinstance(value, str) else json.dumps(value)

    def exists(self, path: str) -> Tuple[Optional[bool], int]:
        """(True|False|None, status) using the metadata-only describe endpoint (never reads data)."""
        status, _ = self.request("GET", f"secrets/{path.strip('/')}::description")
        if status == 200:
            return True, status
        if status == 404:
            return False, status
        return None, status

    def write(self, path: str, data: Dict[str, str], attributes: Optional[dict] = None) -> str:
        """Create or update; returns 'created' | 'updated' | 'unchanged' (compares without exposing values)."""
        path = path.strip("/")
        status, cur = self.request("GET", f"secrets/{path}")
        if status == 200:
            if (cur.get("data") or {}) == data:
                return "unchanged"
            st, _ = self.request("PUT", f"secrets/{path}", {"data": data})
            if st != 200:
                raise DsvError(f"update secrets/{path}: HTTP {st}", st)
            return "updated"
        if status in (403, 404):
            # 403: the publisher may hold create/update but not read; try create, then update.
            st, _ = self.request("POST", f"secrets/{path}", {"data": data, "attributes": attributes or {}})
            if st == 200:
                return "created"
            if st == 400 and status == 403:
                st2, _ = self.request("PUT", f"secrets/{path}", {"data": data})
                if st2 == 200:
                    return "updated"
                st = st2
            raise DsvError(f"create secrets/{path}: HTTP {st}", st)
        raise DsvError(f"read secrets/{path}: HTTP {status}", status)


def client_for(repo: Path, env: Optional[str]) -> Tuple[DsvClient, dict]:
    settings = load_env_settings(repo, env) if env else {}
    return DsvClient(base_url_from(settings)), settings
