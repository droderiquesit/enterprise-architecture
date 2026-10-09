"""dsv-fetch CLI end-to-end (subprocess, `python -I`) against tools/secrets/mock_dsv.py and a fake Azure identity server."""

from __future__ import annotations

import json
import os
import stat

import pytest
import yaml
from conftest import ALL_VALUES, API_VALUE, APP_VALUE, CLIENT_ID, CLIENT_SECRET, MIRID, ODD_VALUE, IdentityServer, base_env, run


def _imds_env(dsv_url: str, identity: IdentityServer, **extra: str) -> dict[str, str]:
    return base_env(DSV_BASE_URL=dsv_url, AZURE_CLIENT_ID=CLIENT_ID, AZURE_POD_IDENTITY_AUTHORITY_HOST=identity.url, **extra)


def _assert_no_values(*texts: str) -> None:
    for text in texts:
        for value in ALL_VALUES:
            assert value not in text


def _mode(path) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


# --------------------------------------------------------------------------------------------- init files
def test_init_files_via_imds_writes_0400_files(dsv, identity, tmp_path):
    url, state = dsv
    out = tmp_path / "secrets"
    p = run(
        [
            "init",
            "--out",
            str(out),
            "--format",
            "files",
            "--map",
            "DD_API_KEY=dsv://eh/dev/datadog-api-key#value",
            "--map",
            "DD_SITE=dsv://eh/dev/datadog-app-key#site",
        ],
        _imds_env(url, identity),
    )
    assert p.returncode == 0, p.stderr
    assert (out / "DD_API_KEY").read_text() == API_VALUE  # exact bytes, no newline
    assert (out / "DD_SITE").read_text() == "datadoghq.eu"
    assert _mode(out / "DD_API_KEY") == 0o400 and _mode(out / "DD_SITE") == 0o400
    assert _mode(out) == 0o700
    assert sorted(os.listdir(out)) == ["DD_API_KEY", "DD_SITE"]  # no temp files left
    _assert_no_values(p.stdout, p.stderr)
    summary = json.loads(p.stderr.strip().splitlines()[-1])
    assert summary["names"] == ["DD_API_KEY", "DD_SITE"] and summary["mode"] == "0400"
    imds = identity.requests[0]
    assert imds["path"] == "/metadata/identity/oauth2/token"
    assert imds["query"] == {"api-version": "2018-02-01", "resource": "https://management.azure.com/", "client_id": CLIENT_ID}
    assert imds["headers"]["Metadata"] == "true"
    assert [c for c in state.calls if c["path"] == "/v1/token"] == [{"method": "POST", "path": "/v1/token", "identity": MIRID}]
    assert len([c for c in state.calls if c["method"] == "GET"]) == 2


def test_init_overwrites_existing_readonly_files(dsv, identity, tmp_path):
    url, _ = dsv
    env = _imds_env(url, identity)
    args = ["init", "--out", str(tmp_path), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"]
    assert run(args, env).returncode == 0
    assert run(args, env).returncode == 0  # re-run (init container restart) replaces the 0400 file atomically
    assert (tmp_path / "K").read_text() == API_VALUE


def test_imds_transient_503_is_retried(dsv, tmp_path):
    url, _ = dsv
    srv = IdentityServer(MIRID, imds_failures=2)
    try:
        p = run(["init", "--out", str(tmp_path), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"], _imds_env(url, srv))
        assert p.returncode == 0, p.stderr
        assert len(srv.requests) == 3
    finally:
        srv.httpd.shutdown()


def test_identity_endpoint_app_service_aca(dsv, identity, tmp_path):
    url, _ = dsv
    env = base_env(DSV_BASE_URL=url, AZURE_CLIENT_ID=CLIENT_ID, IDENTITY_ENDPOINT=f"{identity.url}/msi/token", IDENTITY_HEADER="identity-header-secret")
    p = run(["init", "--out", str(tmp_path), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"], env)
    assert p.returncode == 0, p.stderr
    req = identity.requests[0]
    assert req["path"] == "/msi/token"
    assert req["query"] == {"api-version": "2019-08-01", "resource": "https://management.azure.com/", "client_id": CLIENT_ID}
    assert {k.lower(): v for k, v in req["headers"].items()}["x-identity-header"] == "identity-header-secret"
    assert "identity-header-secret" not in p.stderr + p.stdout


def test_federated_token_file_workload_identity(dsv, identity, tmp_path):
    url, _ = dsv
    tok = tmp_path / "azure-identity-token"
    tok.write_text("federated-sa-token\n")
    out = tmp_path / "out"
    env = base_env(
        DSV_BASE_URL=url, AZURE_CLIENT_ID=CLIENT_ID, AZURE_TENANT_ID="tenant-1", AZURE_AUTHORITY_HOST=identity.url + "/", AZURE_FEDERATED_TOKEN_FILE=str(tok)
    )
    p = run(["init", "--out", str(out), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"], env)
    assert p.returncode == 0, p.stderr
    req = identity.requests[0]
    assert req["path"] == "/tenant-1/oauth2/v2.0/token"
    assert req["form"] == {
        "grant_type": "client_credentials",
        "client_id": CLIENT_ID,
        "scope": "https://management.azure.com/.default",
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": "federated-sa-token",
    }


def test_client_credentials_and_map_file_and_from_env(dsv, tmp_path):
    url, state = dsv
    mf = tmp_path / "map.json"
    mf.write_text(json.dumps({"DD_APP_KEY": "dsv://eh/dev/datadog-app-key"}))
    env = base_env(
        DSV_AUTH="client_credentials",
        DSV_BASE_URL=url,
        DSV_CLIENT_ID="local-client",
        DSV_CLIENT_SECRET=CLIENT_SECRET,
        DD_API_KEY="dsv://eh/dev/datadog-api-key",
    )
    out = tmp_path / "o"
    p = run(["init", "--out", str(out), "--format", "files", "--map-file", str(mf), "--from-env"], env)
    assert p.returncode == 0, p.stderr
    assert (out / "DD_APP_KEY").read_text() == APP_VALUE and (out / "DD_API_KEY").read_text() == API_VALUE
    assert not (out / "DSV_CLIENT_SECRET").exists()
    assert state.calls[0]["identity"] == "local"
    _assert_no_values(p.stdout, p.stderr)


# --------------------------------------------------------------------------------------- env-yaml, dotenv
def test_init_env_yaml_for_fluent_bit(dsv, identity, tmp_path):
    url, _ = dsv
    p = run(
        [
            "init",
            "--out",
            str(tmp_path),
            "--format",
            "env-yaml",
            "--map",
            "DD_API_KEY=dsv://eh/dev/datadog-api-key",
            "--map",
            "ODD=dsv://eh/dev/odd",
            "--file-mode",
            "0440",
        ],
        _imds_env(url, identity),
    )
    assert p.returncode == 0, p.stderr
    f = tmp_path / "fluentbit-env.yaml"
    assert _mode(f) == 0o440
    doc = yaml.safe_load(f.read_text())
    assert doc == {"env": {"DD_API_KEY": API_VALUE, "ODD": ODD_VALUE}}
    _assert_no_values(p.stdout, p.stderr)


def test_init_env_yaml_custom_name(dsv, identity, tmp_path):
    url, _ = dsv
    p = run(
        ["init", "--out", str(tmp_path), "--format", "env-yaml", "--env-yaml-name", "dsv.yaml", "--map", "K=dsv://eh/dev/datadog-api-key"],
        _imds_env(url, identity),
    )
    assert p.returncode == 0 and (tmp_path / "dsv.yaml").exists()


def test_init_dotenv(dsv, identity, tmp_path):
    url, _ = dsv
    p = run(
        ["init", "--out", str(tmp_path), "--format", "dotenv", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key", "--map", "ODD=dsv://eh/dev/odd"],
        _imds_env(url, identity),
    )
    assert p.returncode == 0, p.stderr
    text = (tmp_path / ".env").read_text()
    assert f'DD_API_KEY="{API_VALUE}"\n' in text
    assert 'ODD="we\\"ird \\$HOME \\`x\\` \\\\ ünï \\${DD_API_KEY}"\n' in text
    assert _mode(tmp_path / ".env") == 0o400


def test_dotenv_rejects_multiline_value_without_printing_it(dsv, identity, tmp_path):
    url, _ = dsv
    p = run(["init", "--out", str(tmp_path), "--format", "dotenv", "--map", "M=dsv://eh/dev/odd#multiline"], _imds_env(url, identity))
    assert p.returncode == 1 and "value of M contains a newline" in p.stderr
    assert "a\nb" not in p.stderr
    assert not (tmp_path / ".env").exists()


# ----------------------------------------------------------------------------------------------- failures
def test_any_failure_writes_nothing_and_names_only(dsv, identity, tmp_path):
    url, _ = dsv
    out = tmp_path / "o"
    p = run(
        [
            "init",
            "--out",
            str(out),
            "--format",
            "files",
            "--map",
            "OK=dsv://eh/dev/datadog-api-key",
            "--map",
            "DENIED=dsv://eh/dev/other",
            "--map",
            "GONE=dsv://eh/dev/datadog-nope",
        ],
        _imds_env(url, identity),
    )
    assert p.returncode == 1
    assert "dsv-fetch: DENIED: DSV secret read failed (access denied, HTTP 403)" in p.stderr
    assert "dsv-fetch: GONE: DSV secret read failed (not found, HTTP 404)" in p.stderr
    assert "OK:" not in p.stderr and "not-for-otel" not in p.stderr
    assert not out.exists()
    _assert_no_values(p.stdout, p.stderr)


def test_unknown_identity_is_401(dsv, tmp_path):
    url, _ = dsv
    srv = IdentityServer(mirid="/subscriptions/x/unknown")
    try:
        p = run(["init", "--out", str(tmp_path), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"], _imds_env(url, srv))
        assert p.returncode == 1 and "K: DSV authentication failed (HTTP 401)" in p.stderr
    finally:
        srv.httpd.shutdown()


def test_unreachable_imds(dsv, tmp_path):
    url, _ = dsv
    env = base_env(DSV_BASE_URL=url, AZURE_POD_IDENTITY_AUTHORITY_HOST="http://127.0.0.1:9", DSV_TIMEOUT_SECONDS="0.5", DSV_MAX_ATTEMPTS="1")
    p = run(["init", "--out", str(tmp_path), "--format", "files", "--map", "K=dsv://eh/dev/datadog-api-key"], env)
    assert p.returncode == 1 and "managed identity token unavailable (unreachable" in p.stderr


@pytest.mark.parametrize(
    ("args", "env_extra", "message"),
    [
        (["--format", "files", "--map", "../x=dsv://eh/dev/a"], {}, "invalid NAME"),
        (["--format", "env-yaml", "--map", "dd-key=dsv://eh/dev/a"], {}, "invalid NAME"),
        (["--format", "files", "--map", "K=literal"], {}, "must be a dsv:// reference"),
        (["--format", "files", "--map", "K"], {}, "NAME=dsv://"),
        (["--format", "files"], {}, "nothing to fetch"),
        (["--format", "files", "--map", "K=dsv://eh/dev/a", "--file-mode", "0600"], {}, "--file-mode"),
        (["--format", "files", "--map", "K=dsv://eh/dev/a"], {"DSV_BASE_URL": "http://dsv.example/v1"}, "must use https"),
        (["--format", "files", "--map", "K=dsv://eh/dev/a"], {"DSV_BASE_URL": "", "DSV_TENANT": ""}, "DSV_TENANT or DSV_BASE_URL"),
        (["--format", "files", "--map", "K=dsv://eh/dev/a"], {"DSV_AUTH": "client_credentials"}, "DSV_CLIENT_ID"),
        (["--format", "files", "--map", "K=dsv://eh/dev/a"], {"DSV_AUTH": "none"}, "DSV_AUTH must be"),
    ],
)
def test_usage_errors_exit_2(args, env_extra, message, tmp_path):
    env = base_env(**{"DSV_BASE_URL": "https://dsv.example/v1", **env_extra})
    p = run(["init", "--out", str(tmp_path / "o"), *args], env)
    assert p.returncode == 2, p.stderr
    assert message in p.stderr


def test_argparse_usage_exit_2(tmp_path):
    assert run(["init"], base_env()).returncode == 2
    assert run(["bogus"], base_env()).returncode == 2
    assert run(["version"], base_env()).stdout.strip() == "1.0.0"


# ------------------------------------------------------------------------------------------ agent backend
def test_agent_backend_protocol(dsv, identity):
    url, state = dsv
    req = {
        "version": "1.0",
        "secrets": [
            "dsv://eh/dev/datadog-api-key#value",
            "dsv://eh/dev/datadog-app-key",
            "dsv://eh/dev/other",
            "plain-handle",
            "dsv://eh/dev/datadog-app-key#site",
        ],
    }
    p = run(["agent-backend"], _imds_env(url, identity), stdin=json.dumps(req))
    assert p.returncode == 0, p.stderr
    out = json.loads(p.stdout)
    assert out == {
        "dsv://eh/dev/datadog-api-key#value": {"value": API_VALUE, "error": None},
        "dsv://eh/dev/datadog-app-key": {"value": APP_VALUE, "error": None},
        "dsv://eh/dev/other": {"value": None, "error": "DSV secret read failed (access denied, HTTP 403)"},
        "plain-handle": {"value": None, "error": "not a dsv:// reference"},
        "dsv://eh/dev/datadog-app-key#site": {"value": "datadoghq.eu", "error": None},
    }
    assert p.stderr == ""
    assert len([c for c in state.calls if c["method"] == "GET"]) == 3  # app-key read once for two elements


def test_agent_backend_config_file(dsv, identity, tmp_path):
    url, _ = dsv
    cfg = tmp_path / "dsv-fetch.json"
    cfg.write_text(json.dumps({"DSV_BASE_URL": url, "AZURE_CLIENT_ID": CLIENT_ID, "AZURE_POD_IDENTITY_AUTHORITY_HOST": identity.url, "IGNORED": "x"}))
    p = run(["agent-backend", "--config", str(cfg)], base_env(), stdin='{"version":"1.0","secrets":["dsv://eh/dev/datadog-api-key"]}')
    assert p.returncode == 0
    assert json.loads(p.stdout)["dsv://eh/dev/datadog-api-key"]["value"] == API_VALUE


def test_agent_backend_config_error_is_reported_per_handle():
    p = run(["agent-backend"], base_env(), stdin='{"version":"1.0","secrets":["dsv://eh/dev/a"]}')
    assert p.returncode == 0
    assert json.loads(p.stdout) == {"dsv://eh/dev/a": {"value": None, "error": "dsv-fetch configuration error: DSV_TENANT or DSV_BASE_URL must be set"}}


@pytest.mark.parametrize("stdin", ["", "not json", '{"secrets":[]}', '{"version":"2.0","secrets":[]}', '{"version":"1.0","secrets":"x"}'])
def test_agent_backend_malformed_request_exits_1(stdin):
    p = run(["agent-backend"], base_env(DSV_BASE_URL="https://dsv.example/v1"), stdin=stdin)
    assert p.returncode == 1 and p.stdout == ""


# ---------------------------------------------------------------------------------------------- install
def test_install_writes_0500_copy_with_interpreter(tmp_path, dsv, identity):
    import sys as _sys

    dest = tmp_path / "bin" / "dsv-fetch"
    p = run(["install", "--dest", str(dest), "--python", _sys.executable], base_env())
    assert p.returncode == 0, p.stderr
    assert _mode(dest) == 0o500
    assert dest.read_text().splitlines()[0] == f"#!{_sys.executable} -I"
    import subprocess

    url, _ = dsv
    out = subprocess.run(
        [str(dest), "agent-backend"],
        input='{"version":"1.0","secrets":["dsv://eh/dev/datadog-api-key"]}',
        env=_imds_env(url, identity),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert out.returncode == 0 and json.loads(out.stdout)["dsv://eh/dev/datadog-api-key"]["value"] == API_VALUE
    assert run(["install", "--dest", str(dest), "--python", "python3"], base_env()).returncode == 2
