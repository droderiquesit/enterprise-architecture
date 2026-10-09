"""tools/deploy, tools/validate, tools/smoke, tools/report."""

from __future__ import annotations

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest
import yaml
from fixture_repo import REPO_ROOT, make_synthetic_repo, write

from tools.changeset.select import select_all, select_deploy
from tools.changeset.store import LocalStore
from tools.deploy import plan_manifest, record
from tools.deploy.artifacts import artifacts_tfvars, deterministic_zip
from tools.deploy.retire import main as retire_main
from tools.report import deployment_marker, report
from tools.smoke import smoke
from tools.validate import ownership, plan_policy, versions


# ----------------------------------------------------------------- plan policy
def _plan(changes):
    return {"resource_changes": [{"address": a, "type": t, "mode": "managed", "change": {"actions": acts,
            "before": b, "after": af}} for a, t, acts, b, af in changes]}


def test_plan_policy_blocks_protected_deletes_unless_approved(tmp_path):
    plan = tmp_path / "plan.json"
    plan.write_text(json.dumps(_plan([
        ("azurerm_mssql_database.orders", "azurerm_mssql_database", ["delete", "create"], {}, {}),
        ("azurerm_network_security_rule.x", "azurerm_network_security_rule", ["delete"], {}, None),
        ("azurerm_kubernetes_cluster.aks", "azurerm_kubernetes_cluster", ["update"], {"sku_tier": "Free"}, {"sku_tier": "Standard"}),
        ("azurerm_firewall.fw", "azurerm_firewall", ["create"], None, {}),
    ])))
    out_json = tmp_path / "s.json"
    rc = plan_policy.main(["--plan", str(plan), "--component", "platform-db-sql", "--approvals", str(tmp_path / "none.yaml"),
                           "--summary-json", str(out_json), "--summary-md", str(tmp_path / "s.md")])
    assert rc == 1
    s = json.loads(out_json.read_text())
    assert [v["address"] for v in s["violations"]] == ["azurerm_mssql_database.orders"]
    assert {c["address"] for c in s["cost_flags"]} == {"azurerm_kubernetes_cluster.aks", "azurerm_firewall.fw"}
    appr = tmp_path / "approvals.yaml"
    appr.write_text(yaml.safe_dump({"allow_destroy": [{"component": "platform-db-sql", "addresses": ["azurerm_mssql_database.*"],
                                                       "approved_by": "dba@example.com", "reason": "re-create", "expires_on": "2099-01-01"}]}))
    assert plan_policy.main(["--plan", str(plan), "--component", "platform-db-sql", "--approvals", str(appr)]) == 0
    appr.write_text(appr.read_text().replace("2099-01-01", "2020-01-01"))   # expired approval
    assert plan_policy.main(["--plan", str(plan), "--component", "platform-db-sql", "--approvals", str(appr)]) == 1


# ------------------------------------------------------------- plan manifest
def test_plan_manifest_binding_and_stale_plan(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("BUILD_SOURCEVERSION", "c0ffee")
    monkeypatch.setenv("PLAN_MANIFEST_TERRAFORM_VERSION", "1.16.5")
    root = tmp_path / "root"
    root.mkdir()
    (root / ".terraform.lock.hcl").write_text("# lock\n")
    tfplan = tmp_path / "tfplan"
    tfplan.write_bytes(b"plan-bytes")
    binding = tmp_path / "binding.json"
    binding.write_text(json.dumps({"config_sha": "a", "contracts_sha": "b", "artifacts_sha": "c"}))
    man = tmp_path / "manifest.json"
    common = ["--component", "x", "--env", "dev", "--root", str(root), "--plan", str(tfplan), "--binding", str(binding)]
    assert plan_manifest.main(["create", *common, "--plan-key", "dev/x/1-1.tfplan", "--exit-code", "2", "--out", str(man)]) == 0
    assert json.loads(man.read_text())["has_changes"] is True
    assert plan_manifest.main(["verify", *common, "--manifest", str(man)]) == 0
    binding.write_text(json.dumps({"config_sha": "a", "contracts_sha": "CHANGED", "artifacts_sha": "c"}))
    assert plan_manifest.main(["verify", *common, "--manifest", str(man)]) == 1
    assert "stale plan; re-run" in capsys.readouterr().err
    binding.write_text(json.dumps({"config_sha": "a", "contracts_sha": "b", "artifacts_sha": "c"}))
    tfplan.write_bytes(b"tampered")
    assert plan_manifest.main(["verify", *common, "--manifest", str(man)]) == 1
    monkeypatch.setenv("BUILD_SOURCEVERSION", "other")
    tfplan.write_bytes(b"plan-bytes")
    assert plan_manifest.main(["verify", *common, "--manifest", str(man)]) == 1


# ------------------------------------------------------------------- records
def test_record_failed_keeps_last_succeeded_and_is_reselected(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    store_dir = tmp_path / "records"
    doc = select_deploy(repo, "dev", LocalStore(store_dir))
    sel = tmp_path / "selection.json"
    sel.write_text(json.dumps(doc))
    args = ["write", "--env", "dev", "--component", "platform-db-sql", "--store", str(store_dir), "--selection", str(sel),
            "--commit", "c1", "--run-id", "11"]
    assert record.main([*args, "--status", "succeeded"]) == 0
    assert record.main([*args, "--status", "failed"]) == 0
    rec = LocalStore(store_dir).get_json("dev/platform-db-sql.json")
    assert rec["status"] == "failed" and rec["last_succeeded"]["status"] == "succeeded"
    assert rec["upstream"] == ["foundation-identity", "foundation-network"]
    again = select_deploy(repo, "dev", LocalStore(store_dir))
    assert again["components"]["platform-db-sql"]["plan"]


# ----------------------------------------------------------------- artifacts
def test_deterministic_zip_and_artifact_tfvars(tmp_path):
    src = tmp_path / "src"
    (src / "a").mkdir(parents=True)
    (src / "a/x.txt").write_text("x")
    (src / "y.txt").write_text("y")
    one = deterministic_zip(src, tmp_path / "1.zip")
    os.utime(src / "y.txt", (1, 1))
    assert deterministic_zip(src, tmp_path / "2.zip") == one
    repo = make_synthetic_repo(tmp_path)
    write(repo, "applications/deployments/core-aca/artifacts.tf", 'variable "artifacts" {\n  type = any\n}\n')
    meta = tmp_path / "meta"
    for a, d in (("svc-bff", "sha256:aa"), ("svc-orders-api", "sha256:bb")):
        (meta / a).mkdir(parents=True)
        (meta / a / "build-metadata.json").write_text(json.dumps({"component": a, "name": a, "digest": d,
                                                                   "image": f"r.azurecr.io/{a}@{d}"}))
    entries, digest = artifacts_tfvars(repo, "deploy-core-aca", meta)
    assert entries["svc-bff"]["digest"] == "sha256:aa"
    written = json.loads((repo / "applications/deployments/core-aca/artifacts.auto.tfvars.json").read_text())
    assert written["artifacts"]["svc-orders-api"]["image"].endswith("sha256:bb")
    with pytest.raises(SystemExit):
        artifacts_tfvars(repo, "deploy-frontend", meta)            # svc-frontend metadata missing


# -------------------------------------------------------------------- retire
def test_retire_dry_run_only_touches_scheduled(tmp_path, capsys):
    sel = tmp_path / "sel.json"
    sel.write_text(json.dumps({"retirements": [
        {"component": "b", "status": "retire-scheduled", "order": 1, "path": "p/b", "record_commit": "x"},
        {"component": "a", "status": "retire-scheduled", "order": 0, "path": "p/a", "record_commit": "x"},
        {"component": "c", "status": "retire-pending", "order": None, "path": "p/c"}]}))
    rc = retire_main(["--selection", str(sel), "--env", "dev", "--records-url", str(tmp_path / "r"),
                      "--contracts-url", str(tmp_path / "c"), "--dry-run"])
    out = capsys.readouterr().out
    assert rc == 0 and out.index("retiring a") < out.index("retiring b") and "retiring c" not in out


# ----------------------------------------------------------------- validate
def test_ownership_rules_detect_violations(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    write(repo, "platform/shared/bad.tf", "\n".join([
        'resource "azurerm_monitor_diagnostic_setting" "d" {\n  name = "x"\n}',
        'data "terraform_remote_state" "s" {\n}',
        'resource "datadog_monitor" "m" {\n}',
        'resource "azurerm_redis_cache" "r" {\n}',
        'resource "azurerm_linux_web_app" "w" {\n  name = "dup-app"\n  app_settings = {}\n}',
        '# ownership:allow OWN001 documented exception\nresource "azurerm_monitor_diagnostic_setting" "ok" {\n}',
    ]))
    write(repo, "platform/data/sql/dup.tf", 'resource "azurerm_linux_web_app" "w2" {\n  name = "dup-app"\n}\n')
    write(repo, "observability/modules/x/main.tf", 'module "n" {\n  source = "../../../foundation/modules/naming"\n}\n')
    rules = {f["rule"] for f in ownership.scan(repo)}
    assert rules == {"OWN001", "OWN002", "OWN003", "OWN004", "OWN005", "OWN006", "OWN007"}
    msgs = [f for f in ownership.scan(repo) if f["rule"] == "OWN001"]
    assert len(msgs) == 1


def test_versions_check_detects_mismatch(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    write(repo, "foundation/network/versions.tf",
          'terraform {\n  required_version = ">= 1.0"\n  required_providers {\n    azurerm = {\n'
          '      source  = "hashicorp/azurerm"\n      version = "~> 4.0"\n    }\n  }\n}\n')
    assert versions.main(["--repo", str(repo)]) == 1
    write(repo, "foundation/network/versions.tf",
          'terraform {\n  required_version = ">= 1.14.0, < 2.0.0"\n  required_providers {\n    azurerm = {\n'
          '      source  = "hashicorp/azurerm"\n      version = "~> 5.9"\n    }\n  }\n}\n')
    errs = []
    import io
    import contextlib

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        versions.main(["--repo", str(repo)])
    errs = [l for l in buf.getvalue().splitlines() if l.startswith("ERROR") and "foundation/network:" in l]
    assert errs == ["ERROR: foundation/network: missing committed .terraform.lock.hcl"]


def test_terraform_sh_on_module(tmp_path):
    mod = tmp_path / "mod"
    mod.mkdir()
    (mod / "main.tf").write_text('variable "x" {\n  type    = string\n  default = "a"\n}\n\noutput "y" {\n  value = var.x\n}\n')
    proc = subprocess.run(["bash", str(REPO_ROOT / "tools/validate/terraform.sh"), str(mod), "--clean"],
                          capture_output=True, text=True, timeout=300)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    (mod / "main.tf").write_text('variable "x" {\ntype=string\n}\n')
    proc = subprocess.run(["bash", str(REPO_ROOT / "tools/validate/terraform.sh"), str(mod), "--clean"],
                          capture_output=True, text=True, timeout=300)
    assert proc.returncode != 0


# --------------------------------------------------------------------- smoke
class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path in ("/healthz", "/readyz"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        elif self.path == "/version":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"service":"hello-bff","version":"1"}')
        else:
            self.send_response(503)
            self.end_headers()

    def log_message(self, *a):
        pass


@pytest.fixture()
def http_server():
    srv = HTTPServer(("127.0.0.1", 0), _Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_port}"
    srv.shutdown()


def test_smoke_runner_against_contract_endpoints(tmp_path, http_server):
    contracts = LocalStore(tmp_path / "contracts")
    contracts.put_json("dev/deploy-core-aca/v1.json", {"data": {"endpoints": {"bff": http_server}}})
    contracts.put_json("dev/deploy-frontend/v1.json", {"data": {"api_url": "http://127.0.0.1:9/"}})
    sel = {"components": {
        "deploy-core-aca": {"plan": True, "apply_candidate": True, "layer_name": "applications", "kind": "terraform",
                            "produces": ["deploy-core-aca"]},
        "deploy-frontend": {"plan": True, "apply_candidate": True, "layer_name": "applications", "kind": "terraform",
                            "produces": ["deploy-frontend"]}}}
    res = smoke.run("dev", contracts, sel, [], timeout=3, interval=0.2, attempts=2)
    assert res["components"]["deploy-core-aca"]["status"] == "passed"
    assert res["components"]["deploy-frontend"]["status"] == "failed"
    assert not res["ok"]
    assert smoke.discover({"a": {"web_fqdn": "x.example"}}) == {"a.web_fqdn": "https://x.example"}


# -------------------------------------------------------------------- report
def test_reports_and_markers(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    doc = select_all(repo, "dev", "drift")
    run = tmp_path / "run"
    (run / "selection").mkdir(parents=True)
    (run / "selection/selection.json").write_text(json.dumps(doc))
    for cid, changed in (("foundation-network", True), ("platform-shared", False)):
        d = run / f"plan-{cid}-1"
        d.mkdir()
        (d / "summary.json").write_text(json.dumps({"has_changes": changed, "counts": {"update": 1} if changed else {}}))
        (d / "manifest.json").write_text(json.dumps({"has_changes": changed}))
    out = tmp_path / "drift.md"
    assert report.main(["drift", "--run-dir", str(run), "--out", str(out), "--json", str(tmp_path / "d.json")]) == 0
    assert json.loads((tmp_path / "d.json").read_text())["drift"] == {"foundation-network": {"update": 1}}
    records = LocalStore(tmp_path / "records")
    records.put_json("dev/foundation-network.json", {"status": "succeeded", "run_id": "42", "finished_at": "2026-10-09T10:00:00Z"})
    ev = tmp_path / "evidence.json"
    assert report.main(["deployment", "--run-dir", str(run), "--records", str(tmp_path / "records"), "--env", "dev",
                        "--run-id", "42", "--commit", "abc", "--out", str(tmp_path / "r.md"), "--evidence", str(ev)]) == 0
    evidence = json.loads(ev.read_text())
    assert evidence["components"]["foundation-network"]["status"] == "deployed"
    assert evidence["components"]["platform-shared"]["status"] == "unchanged"
    assert evidence["components"]["platform-db-sql"]["status"] == "skipped"
    bodies = deployment_marker.payloads(evidence, "https://example/repo")
    assert [b["data"]["attributes"]["service"] for b in bodies] == ["foundation-network"]
    attrs = bodies[0]["data"]["attributes"]
    assert attrs["git"]["commit_sha"] == "abc" and attrs["finished_at"] == 1791540000
    assert deployment_marker.main(["--evidence", str(ev), "--repository-url", "u", "--dry-run"]) == 0
