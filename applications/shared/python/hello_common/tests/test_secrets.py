"""hello_common.secrets against tools/secrets/mock_dsv.py (the repository's mock DSV API)."""

from __future__ import annotations

import io
import json
import logging
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from hello_common import secrets as dsv
from hello_common.config import ConfigError, ServiceInfo
from hello_common.logging import JsonFormatter

REPO = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(REPO / "tools" / "secrets"))
mock_dsv = pytest.importorskip("mock_dsv")

MIRID = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-orders"
OTHER = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-other"
FAULT_VALUE = "fault-token-VALUE-7f3a9c"
API_VALUE = "dd-api-key-VALUE-0c41d2"
PG_VALUE = "pg-password-VALUE-99e1"
CLIENT_SECRET = "client-secret-VALUE-5b5b"
ALL_VALUES = (FAULT_VALUE, API_VALUE, PG_VALUE, CLIENT_SECRET)

CFG = {
    "users": {MIRID: {"read": ["eh/dev/orders/*", "eh/dev/datadog-api-key"]}, OTHER: {"read": ["eh/dev/other/*"]}, "local-dev": {"read": ["eh/dev/*"]}},
    "clients": {"local-client": {"secret": CLIENT_SECRET, "identity": "local-dev"}},
    "secrets": {
        "eh/dev/orders/fault-token": {"value": FAULT_VALUE},
        "eh/dev/datadog-api-key": {"value": API_VALUE, "site": "datadoghq.com"},
        "eh/dev/orders/pg": {"value": PG_VALUE, "username": "orders_app", "port": 5432},
    },
}


class FakeCredential:
    def __init__(self, mirid: str = MIRID):
        self.mirid = mirid
        self.calls: list[str] = []

    def get_token(self, scope: str):
        self.calls.append(scope)
        return SimpleNamespace(token=mock_dsv.fake_entra_token(self.mirid), expires_on=9_999_999_999)


class FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


@pytest.fixture
def server():
    httpd, state = mock_dsv.serve(json.loads(json.dumps(CFG)))
    yield f"http://127.0.0.1:{httpd.server_address[1]}/v1", state
    httpd.shutdown()


def _azure_env(base: str, **extra: str) -> dict[str, str]:
    return {"DSV_AUTH": "azure", "DSV_BASE_URL": base, "AZURE_CLIENT_ID": "11111111-2222-3333-4444-555555555555", **extra}


def _client(env: dict[str, str], **kw) -> dsv.DsvClient:
    return dsv.DsvClient(dsv.DsvSettings.from_env(env), sleep=lambda _s: None, **kw)


# ------------------------------------------------------------------------------------------ references
@pytest.mark.parametrize(
    ("ref", "path", "element"),
    [
        ("dsv://eh/dev/datadog-api-key#value", "eh/dev/datadog-api-key", "value"),
        ("dsv://eh/dev/datadog-api-key", "eh/dev/datadog-api-key", "value"),
        ("dsv:///eh/dev/orders/pg#username", "eh/dev/orders/pg", "username"),
    ],
)
def test_parse_reference(ref, path, element):
    assert dsv.SecretRef.parse(ref) == dsv.SecretRef(path, element)


@pytest.mark.parametrize("ref", ["dsv://", "dsv://eh/../x", "dsv://eh/dev/x?y=1", "dsv://eh dev", "dsv://eh/dev/x#a b", "https://x"])
def test_parse_rejects_malformed(ref):
    with pytest.raises(ValueError):
        dsv.SecretRef.parse(ref)


# ------------------------------------------------------------------------------------------ azure grant
def test_resolve_env_azure_grant_replaces_values_in_place(server):
    base, state = server
    cred = FakeCredential()
    env = _azure_env(
        base,
        FAULT_TOKEN="dsv://eh/dev/orders/fault-token#value",
        DD_API_KEY="dsv://eh/dev/datadog-api-key",
        PG_USER="dsv://eh/dev/orders/pg#username",
        PG_PORT="dsv://eh/dev/orders/pg#port",
        PLAIN="not-a-ref",
    )
    with _client(env, credential=cred) as client:
        names = dsv.resolve_env(env, client=client)
        assert client.stats == {"token_requests": 1, "secret_requests": 3, "cache_hits": 1}
    assert names == ["DD_API_KEY", "FAULT_TOKEN", "PG_PORT", "PG_USER"]
    assert env["FAULT_TOKEN"] == FAULT_VALUE
    assert env["DD_API_KEY"] == API_VALUE
    assert env["PG_USER"] == "orders_app"
    assert env["PG_PORT"] == "5432"
    assert env["PLAIN"] == "not-a-ref"
    assert cred.calls == ["https://management.azure.com/.default"]
    token_calls = [c for c in state.calls if c["path"] == "/v1/token"]
    assert token_calls == [{"method": "POST", "path": "/v1/token", "identity": MIRID}]


def test_resolve_env_builds_default_credential(server, monkeypatch):
    """resolve_env() without a client: the managed identity credential is monkeypatched to a fake Entra token."""
    base, _ = server
    made = []

    def fake_default(settings):
        made.append(settings.azure_client_id)
        return FakeCredential()

    monkeypatch.setattr(dsv, "default_credential", fake_default)
    env = _azure_env(base, FAULT_TOKEN="dsv://eh/dev/orders/fault-token")
    assert dsv.resolve_env(env) == ["FAULT_TOKEN"]
    assert env["FAULT_TOKEN"] == FAULT_VALUE
    assert made == ["11111111-2222-3333-4444-555555555555"]


def test_default_credential_selection(monkeypatch):
    from azure import identity

    seen = {}
    monkeypatch.setattr(identity, "ManagedIdentityCredential", lambda **kw: seen.setdefault("mi", kw))
    monkeypatch.setattr(identity, "WorkloadIdentityCredential", lambda **kw: seen.setdefault("wi", kw))
    dsv.default_credential(dsv.DsvSettings(azure_client_id="cid"))
    dsv.default_credential(dsv.DsvSettings(azure_client_id="cid", federated_token_file="/var/run/secrets/azure/tokens/azure-identity-token"))
    assert seen["mi"] == {"client_id": "cid"}
    assert seen["wi"] == {"client_id": "cid", "token_file_path": "/var/run/secrets/azure/tokens/azure-identity-token"}


# ---------------------------------------------------------------------------------- client credentials
def test_client_credentials_grant(server):
    base, state = server
    env = {
        "DSV_AUTH": "client_credentials",
        "DSV_BASE_URL": base,
        "DSV_CLIENT_ID": "local-client",
        "DSV_CLIENT_SECRET": CLIENT_SECRET,
        "X": "dsv://eh/dev/orders/pg",
    }
    assert dsv.resolve_env(env) == ["X"]
    assert env["X"] == PG_VALUE
    assert env["DSV_CLIENT_SECRET"] == CLIENT_SECRET  # DSV_* never treated as references
    assert state.calls[0]["identity"] == "local-dev"


def test_client_credentials_wrong_secret_is_401_not_retried(server):
    base, state = server
    env = {"DSV_AUTH": "client_credentials", "DSV_BASE_URL": base, "DSV_CLIENT_ID": "local-client", "DSV_CLIENT_SECRET": "wrong", "X": "dsv://eh/dev/orders/pg"}
    with pytest.raises(dsv.SecretResolutionError, match=r"X \(DSV authentication failed \(HTTP 401\)\)"):
        dsv.resolve_env(env)
    assert len(state.calls) == 1
    assert env["X"] == "dsv://eh/dev/orders/pg"


# ------------------------------------------------------------------------------------------- failures
def test_forbidden_path_fails_fast_naming_variable_only(server):
    base, state = server
    env = _azure_env(base, OK_VAR="dsv://eh/dev/orders/fault-token", DENIED_VAR="dsv://eh/dev/other/thing", MISSING_VAR="dsv://eh/dev/orders/nope")
    with _client(env, credential=FakeCredential()) as client:
        with pytest.raises(dsv.SecretResolutionError) as err:
            dsv.resolve_env(env, client=client)
    msg = str(err.value)
    assert "DENIED_VAR (DSV secret read failed (access denied, HTTP 403))" in msg
    assert "MISSING_VAR (DSV secret read failed (not found, HTTP 404))" in msg
    assert "OK_VAR" not in msg
    assert "eh/dev/other" not in msg  # references are not echoed either
    assert FAULT_VALUE not in msg
    # all-or-nothing: no variable replaced
    assert env["OK_VAR"] == "dsv://eh/dev/orders/fault-token"
    reads = [c for c in state.calls if c["method"] == "GET"]
    assert len(reads) == 3  # 403/404 are not retried


def test_identity_without_dsv_user_is_unauthorized(server):
    base, _ = server
    env = _azure_env(base, X="dsv://eh/dev/orders/fault-token")
    with _client(env, credential=FakeCredential("/subscriptions/x/unknown")) as client:
        with pytest.raises(dsv.SecretResolutionError, match="HTTP 401"):
            dsv.resolve_env(env, client=client)


def test_missing_element(server):
    base, _ = server
    env = _azure_env(base, X="dsv://eh/dev/orders/fault-token#password")
    with _client(env, credential=FakeCredential()) as client, pytest.raises(dsv.SecretResolutionError, match="element missing"):
        dsv.resolve_env(env, client=client)


def test_credential_failure_is_reported_without_details(server):
    base, _ = server

    class Broken:
        def get_token(self, scope):
            raise RuntimeError(f"IMDS said no; secret={FAULT_VALUE}")

    env = _azure_env(base, X="dsv://eh/dev/orders/fault-token")
    with _client(env, credential=Broken()) as client, pytest.raises(dsv.SecretResolutionError) as err:
        dsv.resolve_env(env, client=client)
    assert "managed identity token unavailable (RuntimeError)" in str(err.value)
    assert FAULT_VALUE not in str(err.value)


def test_auth_none_with_references_is_startup_error():
    env = {"DSV_AUTH": "none", "FAULT_TOKEN": "dsv://eh/dev/orders/fault-token", "B": "dsv://eh/dev/x"}
    with pytest.raises(dsv.SecretResolutionError, match=r"DSV_AUTH=none.*B, FAULT_TOKEN"):
        dsv.resolve_env(env)


def test_no_references_is_noop_without_any_dsv_config():
    env = {"DSV_AUTH": "none", "FAULT_TOKEN": "literal-local-value"}
    assert dsv.resolve_env(env) == []
    assert dsv.resolve_env({"A": "b"}) == []  # DSV_AUTH defaults to azure, still no network


def test_missing_base_url_names_variables():
    with pytest.raises(dsv.SecretResolutionError, match=r"FAULT_TOKEN.*DSV_TENANT or DSV_BASE_URL"):
        dsv.resolve_env({"FAULT_TOKEN": "dsv://eh/dev/x"})


def test_settings_tenant_url_and_https_policy():
    s = dsv.DsvSettings.from_env({"DSV_TENANT": "contoso", "DSV_TLD": "eu"})
    assert s.base_url == "https://contoso.secretsvaultcloud.eu/v1"
    assert dsv.DsvSettings.from_env({"DSV_TENANT": "contoso"}).base_url == "https://contoso.secretsvaultcloud.com/v1"
    with pytest.raises(ConfigError, match="https"):
        dsv.DsvSettings.from_env({"DSV_BASE_URL": "http://mock-dsv:8200/v1"})
    assert dsv.DsvSettings.from_env({"DSV_BASE_URL": "http://mock-dsv:8200/v1", "DSV_ALLOW_INSECURE_HTTP": "true"}).base_url
    assert dsv.DsvSettings.from_env({"DSV_BASE_URL": "http://127.0.0.1:1/v1"}).base_url
    with pytest.raises(ConfigError, match="DSV_CLIENT_ID"):
        dsv.DsvSettings.from_env({"DSV_AUTH": "client_credentials", "DSV_BASE_URL": "https://x/v1"})
    with pytest.raises(ConfigError, match="DSV_AUTH"):
        dsv.DsvSettings.from_env({"DSV_AUTH": "kerberos"})
    assert CLIENT_SECRET not in repr(dsv.DsvSettings(client_secret=CLIENT_SECRET))


# --------------------------------------------------------------------------------- caching + refresh
def test_secret_cache_ttl_and_token_refresh_at_80_percent(server):
    base, state = server
    clock = FakeClock()
    env = _azure_env(base, DSV_CACHE_TTL_SECONDS="900")
    client = _client(env, credential=FakeCredential(), clock=clock)
    ref = "dsv://eh/dev/orders/fault-token"
    assert client.resolve(ref) == FAULT_VALUE
    assert client.resolve(ref) == FAULT_VALUE
    assert client.stats == {"token_requests": 1, "secret_requests": 1, "cache_hits": 1}
    clock.t += 901  # secret TTL expired, token (3600 s, refresh at 2880 s) still fresh
    client.resolve(ref)
    assert client.stats == {"token_requests": 1, "secret_requests": 2, "cache_hits": 1}
    clock.t += 2880 - 901 - 1  # 1 s before 80 % of expiresIn
    client.access_token()
    assert client.stats["token_requests"] == 1
    clock.t += 2  # past 80 %
    client.access_token()
    assert client.stats["token_requests"] == 2
    assert len([c for c in state.calls if c["path"] == "/v1/token"]) == 2
    client.close()


def test_401_on_read_drops_cached_token(server):
    base, state = server
    client = _client(_azure_env(base), credential=FakeCredential())
    client.access_token()
    state.tokens.clear()  # server-side revocation
    with pytest.raises(dsv.DsvRequestError, match="unauthorized"):
        client.secret_data("eh/dev/orders/fault-token")
    assert client.resolve("dsv://eh/dev/orders/fault-token") == FAULT_VALUE
    assert client.stats["token_requests"] == 2
    client.close()


# ------------------------------------------------------------------------------------------- retries
def _scripted(statuses: list[int | Exception]):
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(f"{request.method} {request.url.path}")
        if request.url.path.endswith("/token"):
            return httpx.Response(200, json={"accessToken": "t", "expiresIn": 3600})
        item = statuses.pop(0)
        if isinstance(item, Exception):
            raise item
        if item == 200:
            return httpx.Response(200, json={"data": {"value": "ok-value"}})
        return httpx.Response(item, json={"message": "x"})

    return httpx.MockTransport(handler), seen


@pytest.mark.parametrize(
    "script",
    [[503, 502, 200], [httpx.ConnectError("refused"), 200], [httpx.ReadTimeout("slow"), 429, 200]],
)
def test_transient_failures_are_retried_with_backoff(script):
    transport, seen = _scripted(list(script))
    sleeps: list[float] = []
    client = dsv.DsvClient(
        dsv.DsvSettings.from_env({"DSV_BASE_URL": "https://dsv.example/v1"}), credential=FakeCredential(), transport=transport, sleep=sleeps.append
    )
    assert client.resolve("dsv://eh/dev/a") == "ok-value"
    assert len([s for s in seen if "secrets" in s]) == len(script)
    assert len(sleeps) == len(script) - 1
    assert all(0 <= s <= 2.0 for s in sleeps)


def test_retries_are_bounded():
    transport, seen = _scripted([500, 500, 500, 500])
    client = dsv.DsvClient(
        dsv.DsvSettings.from_env({"DSV_BASE_URL": "https://dsv.example/v1", "DSV_MAX_ATTEMPTS": "3"}),
        credential=FakeCredential(),
        transport=transport,
        sleep=lambda _s: None,
    )
    with pytest.raises(dsv.DsvRequestError, match="HTTP 500 after 3 attempts"):
        client.resolve("dsv://eh/dev/a")
    assert len([s for s in seen if "secrets" in s]) == 3


@pytest.mark.parametrize("status", [400, 401, 403, 404])
def test_client_errors_are_not_retried(status):
    transport, seen = _scripted([status, 200])
    client = dsv.DsvClient(
        dsv.DsvSettings.from_env({"DSV_BASE_URL": "https://dsv.example/v1"}), credential=FakeCredential(), transport=transport, sleep=lambda _s: None
    )
    with pytest.raises(dsv.DsvRequestError, match=f"HTTP {status}"):
        client.resolve("dsv://eh/dev/a")
    assert len([s for s in seen if "secrets" in s]) == 1


def test_unreachable_dsv_fails_after_bounded_attempts():
    env = {"DSV_BASE_URL": "http://127.0.0.1:9/v1", "DSV_TIMEOUT_SECONDS": "0.5", "X": "dsv://eh/dev/a"}
    client = dsv.DsvClient(dsv.DsvSettings.from_env(env), credential=FakeCredential(), sleep=lambda _s: None)
    with pytest.raises(dsv.SecretResolutionError, match=r"X \(DSV authentication failed \(DSV unreachable \(ConnectError\)\)\)"):
        dsv.resolve_env(env, client=client)


# ---------------------------------------------------------------------------- no values in log output
def test_no_secret_value_in_log_output(server, caplog):
    base, _ = server
    buf = io.StringIO()
    handler = logging.StreamHandler(buf)
    handler.setFormatter(JsonFormatter(ServiceInfo(service="t", version="1", env="test")))
    root = logging.getLogger()
    root.addHandler(handler)
    old_level = root.level
    root.setLevel(logging.DEBUG)
    try:
        with caplog.at_level(logging.DEBUG):
            ok = _azure_env(base, FAULT_TOKEN="dsv://eh/dev/orders/fault-token", DD_API_KEY="dsv://eh/dev/datadog-api-key", PGPW="dsv://eh/dev/orders/pg")
            with _client(ok, credential=FakeCredential()) as client:
                dsv.resolve_env(ok, client=client)
            bad = _azure_env(base, FAULT_TOKEN="dsv://eh/dev/orders/fault-token", DENIED="dsv://eh/dev/other/x")
            with _client(bad, credential=FakeCredential()) as client, pytest.raises(dsv.SecretResolutionError):
                dsv.resolve_env(bad, client=client)
            cc = {
                "DSV_AUTH": "client_credentials",
                "DSV_BASE_URL": base,
                "DSV_CLIENT_ID": "local-client",
                "DSV_CLIENT_SECRET": CLIENT_SECRET,
                "Y": "dsv://eh/dev/orders/pg",
            }
            dsv.resolve_env(cc)
    finally:
        root.removeHandler(handler)
        root.setLevel(old_level)
    text = buf.getvalue() + "\n".join(r.getMessage() + repr(r.__dict__) for r in caplog.records)
    assert "DSV secrets resolved" in text
    assert "DSV secret resolution failed" in text
    for value in ALL_VALUES:
        assert value not in text
