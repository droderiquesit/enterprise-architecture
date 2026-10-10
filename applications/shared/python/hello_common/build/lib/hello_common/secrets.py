"""Delinea DevOps Secrets Vault (DSV) reference resolution (ADR-0001 §14).

Any environment variable whose *value* starts with ``dsv://`` is a secret reference::

    FAULT_TOKEN=dsv://eh/dev/orders-fault-token#value      (element defaults to "value")

``resolve_env()`` replaces every such value in-process with the secret read from DSV, once, at start-up and before
any client is built (each service entrypoint calls it; ``hello_common.app.create_app`` calls it again as a no-op
safety net). Values only ever live in process memory: they are never logged, never put into exception messages and
never written to disk. A reference that cannot be resolved stops the process with ``SecretResolutionError`` naming
the variable (not the reference, not the value).

Protocol (Delinea dsv-sdk-go v2.3.0, auth/azure.go + vault/vault.go):

1. Entra access token for ``https://management.azure.com/`` from the workload's user-assigned managed identity
   (``AZURE_CLIENT_ID``): ``WorkloadIdentityCredential`` when ``AZURE_FEDERATED_TOKEN_FILE`` is set (AKS workload
   identity), otherwise ``ManagedIdentityCredential`` (IMDS on VMs/VMSS/Batch/ACI, ``IDENTITY_ENDPOINT`` on App
   Service/Functions/Container Apps).
2. ``POST {base}/token {"grant_type":"azure","jwt":"<entra token>"}`` -> ``{"accessToken","expiresIn"}``; the DSV
   token is cached and refreshed at 80 % of ``expiresIn``.
3. ``GET {base}/secrets/<path>`` with ``Authorization: Bearer`` -> ``{"data": {...}}``; cached for
   ``DSV_CACHE_TTL_SECONDS``.

Environment:

=========================  ===================================================================================
DSV_AUTH                   ``azure`` (default) | ``client_credentials`` (local/test: DSV_CLIENT_ID +
                           DSV_CLIENT_SECRET) | ``none`` (no resolution: any dsv:// value is a start-up error)
DSV_TENANT, DSV_TLD        base URL ``https://{DSV_TENANT}.secretsvaultcloud.{DSV_TLD:-com}/v1``
DSV_BASE_URL               override (mock server: ``http://127.0.0.1:<port>/v1``). ``http://`` is accepted only
                           for loopback hosts or with ``DSV_ALLOW_INSECURE_HTTP=true`` (local docker tests)
AZURE_CLIENT_ID            user-assigned managed identity client id (azure auth)
DSV_TIMEOUT_SECONDS        per-request timeout, default 5
DSV_CACHE_TTL_SECONDS      secret cache TTL, default 900
DSV_MAX_ATTEMPTS           attempts for transient failures (connection errors, timeouts, 429, 5xx), default 3;
                           401/403/404 and other 4xx are never retried
=========================  ===================================================================================
"""

from __future__ import annotations

import ipaddress
import logging
import os
import random
import re
import threading
import time
from collections.abc import Callable, MutableMapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urlsplit

import httpx

from .config import ConfigError

REF_PREFIX = "dsv://"
ARM_SCOPE = "https://management.azure.com/.default"
TOKEN_REFRESH_FRACTION = 0.8
DEFAULT_ELEMENT = "value"
AUTH_MODES = frozenset({"azure", "client_credentials", "none"})

log = logging.getLogger("hello.secrets")

_PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*$")
_ELEMENT_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_TRUE = {"1", "true", "yes", "on"}


class SecretResolutionError(ConfigError):
    """A DSV reference could not be resolved. Messages never contain secret values."""


class DsvRequestError(Exception):
    """Internal: one DSV call failed. ``reason`` is safe to log (status code / error class only)."""

    def __init__(self, reason: str, status: int | None = None) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status


@dataclass(frozen=True)
class SecretRef:
    path: str
    element: str = DEFAULT_ELEMENT

    @classmethod
    def parse(cls, ref: str) -> SecretRef:
        if not ref.startswith(REF_PREFIX):
            raise ValueError("not a dsv:// reference")
        body = ref[len(REF_PREFIX) :]
        path, _, element = body.partition("#")
        path = path.strip("/")
        element = element or DEFAULT_ELEMENT
        if not path or ".." in path.split("/") or not _PATH_RE.match(path):
            raise ValueError("malformed dsv:// reference path")
        if not _ELEMENT_RE.match(element):
            raise ValueError("malformed dsv:// reference element")
        return cls(path, element)


def is_reference(value: str | None) -> bool:
    return bool(value) and value.startswith(REF_PREFIX)  # type: ignore[union-attr]


def _num(env: MutableMapping[str, str], name: str, default: float, minimum: float) -> float:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise ConfigError(f"environment variable {name} must be a number") from exc
    if value < minimum:
        raise ConfigError(f"environment variable {name} must be >= {minimum:g}")
    return value


@dataclass(frozen=True)
class DsvSettings:
    auth: str = "azure"
    base_url: str | None = None
    azure_client_id: str | None = None
    federated_token_file: str | None = None
    client_id: str | None = None
    client_secret: str | None = None
    timeout_seconds: float = 5.0
    cache_ttl_seconds: float = 900.0
    max_attempts: int = 3

    def __repr__(self) -> str:  # never print the client secret
        return f"DsvSettings(auth={self.auth!r}, base_url={self.base_url!r}, azure_client_id={self.azure_client_id!r})"

    @classmethod
    def from_env(cls, env: MutableMapping[str, str] | None = None) -> DsvSettings:
        env = os.environ if env is None else env
        auth = (env.get("DSV_AUTH") or "azure").strip().lower()
        if auth not in AUTH_MODES:
            raise ConfigError(f"environment variable DSV_AUTH must be one of {sorted(AUTH_MODES)}")
        base = (env.get("DSV_BASE_URL") or "").strip().rstrip("/")
        if not base and env.get("DSV_TENANT"):
            base = f"https://{env['DSV_TENANT'].strip()}.secretsvaultcloud.{(env.get('DSV_TLD') or 'com').strip()}/v1"
        return cls(
            auth=auth,
            base_url=base or None,
            azure_client_id=(env.get("AZURE_CLIENT_ID") or "").strip() or None,
            federated_token_file=(env.get("AZURE_FEDERATED_TOKEN_FILE") or "").strip() or None,
            client_id=(env.get("DSV_CLIENT_ID") or "").strip() or None,
            client_secret=env.get("DSV_CLIENT_SECRET") or None,
            timeout_seconds=_num(env, "DSV_TIMEOUT_SECONDS", 5.0, 0.1),
            cache_ttl_seconds=_num(env, "DSV_CACHE_TTL_SECONDS", 900.0, 0),
            max_attempts=int(_num(env, "DSV_MAX_ATTEMPTS", 3, 1)),
        )._validated((env.get("DSV_ALLOW_INSECURE_HTTP") or "").strip().lower() in _TRUE)

    def _validated(self, allow_http: bool) -> DsvSettings:
        if self.auth == "none":
            return self
        if not self.base_url:
            raise ConfigError("DSV_TENANT or DSV_BASE_URL must be set to resolve dsv:// references")
        parts = urlsplit(self.base_url)
        if parts.scheme not in ("https", "http") or not parts.hostname:
            raise ConfigError("DSV_BASE_URL must be an absolute https URL")
        if parts.scheme == "http" and not (allow_http or _is_loopback(parts.hostname)):
            raise ConfigError("DSV_BASE_URL must use https (http only for loopback or DSV_ALLOW_INSECURE_HTTP=true)")
        if self.auth == "client_credentials" and not (self.client_id and self.client_secret):
            raise ConfigError("DSV_AUTH=client_credentials requires DSV_CLIENT_ID and DSV_CLIENT_SECRET")
        return self


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def default_credential(settings: DsvSettings) -> Any:
    """Managed identity credential for the DSV azure grant (no developer-credential fallbacks)."""
    from azure import identity

    if settings.federated_token_file:
        return identity.WorkloadIdentityCredential(client_id=settings.azure_client_id, token_file_path=settings.federated_token_file)
    return identity.ManagedIdentityCredential(client_id=settings.azure_client_id)


class DsvClient:
    """Thread-safe DSV reader with a DSV-token cache (refresh at 80 % of expiresIn) and a TTL secret cache."""

    def __init__(
        self,
        settings: DsvSettings,
        *,
        credential: Any | None = None,
        transport: httpx.BaseTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if settings.auth == "none":
            raise ConfigError("DSV_AUTH=none: dsv:// references cannot be resolved")
        self.settings = settings
        self._credential = credential
        self._clock = clock
        self._sleep = sleep
        self._lock = threading.RLock()
        self._token: str | None = None
        self._token_refresh_at = 0.0
        self._cache: dict[str, tuple[dict[str, Any], float]] = {}
        self._http = httpx.Client(
            base_url=settings.base_url or "",
            timeout=httpx.Timeout(settings.timeout_seconds),
            transport=transport,
            headers={"Accept": "application/json", "User-Agent": "hello-common-dsv/1"},
            follow_redirects=False,
            trust_env=True,
        )
        self.stats = {"token_requests": 0, "secret_requests": 0, "cache_hits": 0}

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> DsvClient:
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    # ------------------------------------------------------------------------------------------- http
    def _request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        attempts = max(1, self.settings.max_attempts)
        for attempt in range(1, attempts + 1):
            try:
                resp = self._http.request(method, url, **kwargs)
            except httpx.TransportError as exc:  # connection refused/reset, DNS, timeouts
                if attempt == attempts:
                    raise DsvRequestError(f"DSV unreachable ({type(exc).__name__})") from None
            else:
                if resp.status_code < 400:
                    return resp
                if resp.status_code != 429 and resp.status_code < 500:
                    raise DsvRequestError(f"HTTP {resp.status_code}", resp.status_code)
                if attempt == attempts:
                    raise DsvRequestError(f"HTTP {resp.status_code} after {attempts} attempts", resp.status_code)
            self._sleep(random.uniform(0, min(2.0, 0.25 * 2 ** (attempt - 1))))
        raise AssertionError("unreachable")

    # ------------------------------------------------------------------------------------------ token
    def _grant_body(self) -> dict[str, str]:
        if self.settings.auth == "client_credentials":
            return {"grant_type": "client_credentials", "client_id": self.settings.client_id or "", "client_secret": self.settings.client_secret or ""}
        cred = self._credential
        if cred is None:
            cred = self._credential = default_credential(self.settings)
        try:
            entra = cred.get_token(ARM_SCOPE).token
        except Exception as exc:
            raise DsvRequestError(f"managed identity token unavailable ({type(exc).__name__})") from None
        return {"grant_type": "azure", "jwt": entra}

    def access_token(self) -> str:
        with self._lock:
            if self._token is not None and self._clock() < self._token_refresh_at:
                return self._token
            body = self._grant_body()
            self.stats["token_requests"] += 1
            try:
                resp = self._request("POST", "/token", json=body)
            except DsvRequestError as exc:
                raise DsvRequestError(f"DSV authentication failed ({exc.reason})", exc.status) from None
            try:
                doc = resp.json()
                token = doc["accessToken"]
                expires_in = float(doc.get("expiresIn") or 3600)
            except (ValueError, KeyError, TypeError):
                raise DsvRequestError("DSV token response malformed") from None
            self._token = token
            self._token_refresh_at = self._clock() + expires_in * TOKEN_REFRESH_FRACTION
            return token

    def invalidate_token(self) -> None:
        with self._lock:
            self._token = None

    # ---------------------------------------------------------------------------------------- secrets
    def secret_data(self, path: str) -> dict[str, Any]:
        path = path.strip("/")
        with self._lock:
            hit = self._cache.get(path)
            if hit is not None and self._clock() < hit[1]:
                self.stats["cache_hits"] += 1
                return hit[0]
            token = self.access_token()
            self.stats["secret_requests"] += 1
            try:
                resp = self._request("GET", f"/secrets/{quote(path, safe='/')}", headers={"Authorization": f"Bearer {token}"})
            except DsvRequestError as exc:
                if exc.status == 401:  # token revoked/expired early: next call re-authenticates (no retry here)
                    self._token = None
                reason = {401: "unauthorized", 403: "access denied", 404: "not found"}.get(exc.status or 0)
                raise DsvRequestError(f"DSV secret read failed ({reason + ', ' if reason else ''}{exc.reason})", exc.status) from None
            try:
                data = resp.json().get("data")
            except (ValueError, AttributeError):
                data = None
            if not isinstance(data, dict):
                raise DsvRequestError("DSV secret response malformed")
            self._cache[path] = (data, self._clock() + self.settings.cache_ttl_seconds)
            return data

    def resolve(self, ref: str | SecretRef) -> str:
        parsed = ref if isinstance(ref, SecretRef) else SecretRef.parse(ref)
        data = self.secret_data(parsed.path)
        if parsed.element not in data:
            raise DsvRequestError("element missing in DSV secret")
        value = data[parsed.element]
        if value is None:
            raise DsvRequestError("element is null in DSV secret")
        return value if isinstance(value, str) else str(value)


_client_lock = threading.Lock()
_client: DsvClient | None = None


def get_client(env: MutableMapping[str, str] | None = None) -> DsvClient:
    """Process-wide client (lazily created from the environment)."""
    global _client
    with _client_lock:
        if _client is None:
            _client = DsvClient(DsvSettings.from_env(env))
        return _client


def reset_client() -> None:
    global _client
    with _client_lock:
        if _client is not None:
            _client.close()
        _client = None


def resolve_env(environ: MutableMapping[str, str] | None = None, *, client: DsvClient | None = None) -> list[str]:
    """Replace every ``dsv://`` value in ``environ`` (default ``os.environ``) with the secret value, in place.

    Returns the names of the variables that were resolved (never the values). Raises ``SecretResolutionError``
    naming every variable that could not be resolved; nothing is replaced unless all references resolve.
    """
    env = os.environ if environ is None else environ
    refs = {name: value for name, value in env.items() if is_reference(value) and not name.startswith("DSV_")}
    if not refs:
        return []
    names = sorted(refs)
    auth = (env.get("DSV_AUTH") or "azure").strip().lower()
    if client is None and auth == "none":
        raise SecretResolutionError(f"DSV_AUTH=none but environment variables hold dsv:// references: {', '.join(names)}")
    if client is None:
        try:
            client = DsvClient(DsvSettings.from_env(env))
        except ConfigError as exc:
            raise SecretResolutionError(f"cannot resolve dsv:// references in {', '.join(names)}: {exc}") from None
        own = True
    else:
        own = False
    resolved: dict[str, str] = {}
    failures: list[str] = []
    try:
        for name in names:
            try:
                resolved[name] = client.resolve(refs[name])
            except ValueError:
                failures.append(f"{name} (malformed dsv:// reference)")
            except DsvRequestError as exc:
                failures.append(f"{name} ({exc.reason})")
    finally:
        if own:
            client.close()
    if failures:
        log.error("DSV secret resolution failed", extra={"variables": [f.split(" ", 1)[0] for f in failures]})
        raise SecretResolutionError("could not resolve DSV secret for environment variable(s): " + "; ".join(failures))
    for name, value in resolved.items():
        env[name] = value
    log.info("DSV secrets resolved", extra={"variables": names, "count": len(names)})
    return names
