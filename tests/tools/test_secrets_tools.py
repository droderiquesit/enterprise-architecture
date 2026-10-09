"""tools/secrets: dsv_apply plan/apply, fetch, check and publish end-to-end against tools/secrets/mock_dsv.py.

The desired state is rendered by the real foundation/secrets root (`terraform apply` of a provider-less copy with
local state) when terraform is on PATH; otherwise the test is skipped.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from tools.secrets import check, dsv_apply, fetch, publish
from tools.secrets.dsvlib import DsvClient, DsvError, parse_ref, secret_spec
from tools.secrets.mock_dsv import fake_entra_token, serve

REPO = Path(__file__).resolve().parents[2]
SUB = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities"
MIRID = {k: f"{SUB}/eh-id-{k}-dev-sec" for k in ("hello-bff", "obs-collector", "deploy-agent")}
SECRETS = {
    "eh/dev/fault-token": {"value": "ft-value-123"},
    "eh/dev/datadog-api-key": {"value": "dd-api-value-456"},
    "eh/dev/datadog-app-key": {"value": "dd-app-value-789"},
    "eh/dev/fluentbit-shared-key": {"value": "fb-value"},
    "eh/dev/appgw-tls-pfx": {"value": "cGZ4", "password": "pfx-pass"},
}
VALUES = [v for d in SECRETS.values() for v in d.values()]


def identity_contract():
    ids = {
        "hello-bff": ["fault-token", "datadog-api-key"],
        "obs-collector": ["datadog-api-key", "fluentbit-shared-key", "eventhub-fluentbit-listen"],
        "deploy-agent": ["datadog-api-key", "datadog-app-key", "appgw-tls-pfx"],
        "aks-kubelet": [],
    }
    names = sorted({s for v in ids.values() for s in v})
    return {
        "identities": {k: {"id": f"{SUB}/eh-id-{k}-dev-sec", "name": f"eh-id-{k}-dev-sec", "secrets": v} for k, v in ids.items()},
        "secrets": {"tenant": "example-lab", "tld": "com", "base_url": "https://example-lab.secretsvaultcloud.com/v1",
                    "base_path": "eh/dev", "auth_provider": "azure-eh",
                    "refs": {n: f"dsv://eh/dev/{n}#value" for n in names}},
    }


@pytest.fixture(scope="module")
def desired(tmp_path_factory):
    if not shutil.which("terraform"):
        pytest.skip("terraform not on PATH")
    work = tmp_path_factory.mktemp("fs")
    (work / "foundation" / "identity").mkdir(parents=True)
    shutil.copy(REPO / "foundation/identity/secrets.yaml", work / "foundation/identity/secrets.yaml")
    root = work / "foundation" / "secrets"
    shutil.copytree(REPO / "foundation/secrets", root, ignore=shutil.ignore_patterns(".terraform", "tests", "backend.tf"))
    env = json.loads(json.dumps({"name": "dev", "location": "swedencentral", "subscription_id": "00000000-0000-0000-0000-000000000000",
                                 "tenant_id": "11111111-2222-3333-4444-555555555555", "name_prefix": "eh", "owner": "o",
                                 "team": "t", "cost_center": "c", "expires_on": "2026-12-31", "tags": {}}))
    (root / "terraform.tfvars.json").write_text(json.dumps({"environment": env, "foundation_identity": identity_contract()}))
    for cmd in (["init", "-backend=false", "-input=false"], ["apply", "-auto-approve", "-input=false"]):
        p = subprocess.run(["terraform", f"-chdir={root}", *cmd], capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
    out = subprocess.run(["terraform", f"-chdir={root}", "output", "-json", "dsv_desired_state"], capture_output=True, text=True)
    state = json.loads(out.stdout)
    path = work / "desired.json"
    path.write_text(json.dumps(state))
    return state, path


@pytest.fixture()
def dsv():
    httpd, st = serve({"users": {MIRID["deploy-agent"]: {"admin": True}}, "secrets": SECRETS})
    yield f"http://127.0.0.1:{httpd.server_address[1]}/v1", st
    httpd.shutdown()


@pytest.fixture()
def imds(monkeypatch):
    """Fake IMDS returning an (unsigned) Entra token of the deploy agent identity."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):  # noqa: N802
            assert self.headers.get("Metadata") == "true"
            raw = json.dumps({"access_token": fake_entra_token(H.mirid), "expires_in": "3600"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(raw)

    H.mirid = MIRID["deploy-agent"]
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    monkeypatch.setenv("DSV_IMDS_ENDPOINT", f"http://127.0.0.1:{srv.server_address[1]}")
    monkeypatch.setenv("DSV_AUTH", "azure")
    monkeypatch.delenv("IDENTITY_ENDPOINT", raising=False)
    yield H
    srv.shutdown()


def test_refs_and_specs():
    assert parse_ref("dsv://eh/dev/datadog-api-key#value") == ("eh/dev/datadog-api-key", "value")
    assert parse_ref("dsv://eh/dev/x") == ("eh/dev/x", "value")
    assert secret_spec("eh/dev", "appgw-tls-pfx#password?") == ("eh/dev/appgw-tls-pfx", "password", True)
    with pytest.raises(DsvError):
        parse_ref("https://kv.vault.azure.net/secrets/x")
    with pytest.raises(DsvError):
        parse_ref("dsv://eh/../x#value")


def test_desired_state_shape(desired):
    state, _ = desired
    assert set(state["users"]) == {"eh-dev-hello-bff", "eh-dev-obs-collector", "eh-dev-deploy-agent"}
    assert state["auth_provider"] == {"name": "azure-eh", "type": "azure", "tenant_id": "11111111-2222-3333-4444-555555555555"}
    perms = {p["key"]: p for p in state["policy"]["permissions"]}
    assert perms["read:hello-bff"]["resources"] == ["secrets:eh:dev:datadog-api-key", "secrets:eh:dev:fault-token"]
    assert perms["publish:deploy-agent"]["actions"] == ["create", "update"]


def test_dsv_apply_converges_and_grants_least_privilege(desired, dsv, imds, capsys):
    state, path = desired
    base, st = dsv
    # an operator-owned permission in the same policy must survive
    st.policies["secrets:eh:dev"] = {"path": "secrets:eh:dev", "version": "0", "permissionDocument": [
        {"description": "operator break-glass", "subjects": ["users:<ops>"], "effect": "allow", "actions": ["read"],
         "resources": ["secrets:eh:dev:<.*>"]}]}
    assert dsv_apply.main(["plan", "--state", str(path), "--base-url", base]) == 2
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 0
    assert dsv_apply.main(["plan", "--state", str(path), "--base-url", base]) == 0
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 0  # idempotent
    assert st.auth_providers["azure-eh"]["properties"]["tenantId"] == "11111111-2222-3333-4444-555555555555"
    assert st.dsv_users["azure-eh:eh-dev-hello-bff"]["externalId"] == MIRID["hello-bff"]
    descs = [p["description"] for p in st.policies["secrets:eh:dev"]["permissionDocument"]]
    assert descs[0] == "operator break-glass" and sum(d.startswith("managed-by:foundation-secrets ") for d in descs) == 5

    # the workload authenticates with ITS identity and reads exactly its paths
    imds.mirid = MIRID["hello-bff"]
    c = DsvClient(base)
    assert c.get_value("dsv://eh/dev/fault-token#value") == "ft-value-123"
    with pytest.raises(DsvError) as exc:
        c.get_value("dsv://eh/dev/datadog-app-key#value")
    assert exc.value.status == 403
    out = capsys.readouterr()
    assert not any(v in out.out + out.err for v in VALUES)


def test_dsv_apply_conflict_changes_nothing(desired, dsv, imds):
    _state, path = desired
    base, st = dsv
    st.dsv_users["azure-eh:eh-dev-hello-bff"] = {"userName": "eh-dev-hello-bff", "provider": "azure-eh",
                                                "externalId": "/subscriptions/x/other", "displayName": "x", "version": "0"}
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 1
    assert "secrets:eh:dev" not in st.policies and "azure-eh" not in st.auth_providers


def test_dsv_apply_updates_managed_and_reports_orphans(desired, dsv, imds, capsys):
    state, path = desired
    base, st = dsv
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 0
    st.dsv_users["azure-eh:eh-dev-hello-bff"]["displayName"] = "managed-by:foundation-secrets eh/dev stale"
    st.dsv_users["azure-eh:eh-dev-gone"] = {"userName": "eh-dev-gone", "provider": "azure-eh", "externalId": "/x",
                                            "displayName": "managed-by:foundation-secrets eh/dev gone", "version": "0"}
    capsys.readouterr()
    assert dsv_apply.main(["plan", "--state", str(path), "--base-url", base]) == 2
    out = capsys.readouterr().out
    assert "update    user          azure-eh:eh-dev-hello-bff" in out and "orphan    user          azure-eh:eh-dev-gone" in out
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 0
    assert "azure-eh:eh-dev-gone" in st.dsv_users  # never deleted


def test_fetch_exec_and_ado(dsv, imds, monkeypatch, capfd):
    base, _st = dsv
    monkeypatch.setenv("DSV_BASE_URL", base)
    probe = "import os,sys; sys.stdout.write(str(len(os.environ.get('TF_VAR_tls_certificate_password',''))) + ':' + str('TF_VAR_x' in os.environ))"
    proc = subprocess.run([sys.executable, "tools/secrets/fetch.py", "exec", "--env", "dev", "--component", "foundation-edge",
                           "--map", "TF_VAR_x=does-not-exist?", "--", sys.executable, "-c", probe],
                          cwd=REPO, capture_output=True, text=True, env={**os.environ})
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "8:False"
    assert not any(v in proc.stdout + proc.stderr for v in VALUES)
    # required secret missing -> exit 1 naming the variable only
    proc = subprocess.run([sys.executable, "tools/secrets/fetch.py", "exec", "--env", "dev", "--map", "X=missing-secret",
                           "--", "true"], cwd=REPO, capture_output=True, text=True)
    assert proc.returncode == 1 and "X: cannot read eh/dev/missing-secret" in proc.stderr
    assert fetch.main(["ado", "--env", "dev", "--map", "DD_API_KEY=datadog-api-key", "--repo", str(REPO)]) == 0
    out = capfd.readouterr().out
    assert "##vso[task.setvariable variable=DD_API_KEY;issecret=true]dd-api-value-456" in out
    assert fetch.ado_escape("a%b\nc") == "a%AZP25b%0Ac"


def test_check_reports_missing_without_values(desired, dsv, imds, monkeypatch, capsys):
    base, _st = dsv
    monkeypatch.setenv("DSV_BASE_URL", base)
    assert check.main(["--env", "dev", "--names", "fault-token,datadog-api-key", "--repo", str(REPO)]) == 0
    assert check.main(["--env", "dev", "--names", "fault-token,sqlvm-admin-password", "--repo", str(REPO)]) == 1
    assert check.main(["--env", "dev", "--names", "eventhub-fluentbit-listen", "--repo", str(REPO)]) == 0  # generated: warning
    assert check.main(["--env", "dev", "--names", "eventhub-fluentbit-listen", "--strict", "--repo", str(REPO)]) == 1
    assert check.main(["--env", "dev", "--names", "not-catalogued", "--repo", str(REPO)]) == 1
    out = capsys.readouterr()
    assert "MISSING" in out.out and not any(v in out.out + out.err for v in VALUES)
    calls = [c["path"] for c in json.loads(__import__("urllib.request").request.urlopen(f"{base}/__calls").read())["calls"]]
    assert all(not c.startswith("eh/dev/") or c in ("eh/dev/fault-token", "eh/dev/datadog-api-key", "eh/dev/sqlvm-admin-password",
                                                     "eh/dev/eventhub-fluentbit-listen") for c in calls)


def test_check_required_set_follows_enabled_components():
    from tools.secrets.catalog import required

    need = required(REPO, "dev", enabled={"obs-prereqs", "platform-db-sqlvm", "platform-db-mysql"})
    assert need["datadog-app-key"] == ["obs-prereqs"]
    assert "sqlvm-admin-password" in need and "mysql-admin-password" not in need  # optional input


def test_publish_generated_only(desired, dsv, imds, monkeypatch, tmp_path, capsys):
    _state, path = desired
    base, st = dsv
    monkeypatch.setenv("DSV_BASE_URL", base)
    vals = tmp_path / "out.json"
    vals.write_text(json.dumps({"eventhub-fluentbit-listen": "Endpoint=sb://x/;SharedAccessKey=generated-zzz"}))
    args = ["--env", "dev", "--component", "obs-telemetry-transport", "--output-json", str(vals), "--repo", str(REPO)]
    assert publish.main(args) == 0
    assert publish.main(args) == 0
    out = capsys.readouterr().out
    assert "eventhub-fluentbit-listen: created" in out and "eventhub-fluentbit-listen: unchanged" in out
    assert "generated-zzz" not in out
    assert st.secrets["eh/dev/eventhub-fluentbit-listen"]["data"]["value"].endswith("generated-zzz")
    vals.write_text(json.dumps({"fault-token": "x"}))
    assert publish.main(args) == 1
    # the publisher permission (not admin) is enough once foundation-secrets is applied
    assert dsv_apply.main(["apply", "--state", str(path), "--base-url", base]) == 0
    st.users.pop(MIRID["deploy-agent"])  # drop the bootstrap admin mapping: only the managed permissions remain
    vals.write_text(json.dumps({"eventhub-fluentbit-listen": "Endpoint=sb://x/;SharedAccessKey=rotated"}))
    assert publish.main(args) == 0
    assert st.secrets["eh/dev/eventhub-fluentbit-listen"]["version"] == 2


def test_hooks_post_plan_and_post_apply(desired, dsv, imds, monkeypatch, tmp_path, capsys):
    from tools.secrets import hooks

    state, _ = desired
    base, st = dsv
    monkeypatch.setenv("DSV_BASE_URL", base)
    plan = tmp_path / "plan.json"
    plan.write_text(json.dumps({"planned_values": {"outputs": {"dsv_desired_state": {"sensitive": False, "value": state}}}}))
    summary = tmp_path / "summary.md"
    args = ["--env", "dev", "--component", "foundation-secrets", "--root", "foundation/secrets", "--repo", str(REPO)]
    assert hooks.main(["post-plan", *args, "--plan-json", str(plan), "--summary-md", str(summary)]) == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "dsv_changes=true"
    assert "| create | user | `azure-eh:eh-dev-hello-bff` |" in summary.read_text()
    # components without secret hooks are a no-op
    assert hooks.main(["post-plan", "--env", "dev", "--component", "foundation-network", "--root", "foundation/network",
                       "--repo", str(REPO)]) == 0
    assert capsys.readouterr().out.strip() == "dsv_changes=false"
