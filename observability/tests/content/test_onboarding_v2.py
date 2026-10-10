"""Core onboarding (manifest v2): identity + tags + resources + telemetry routing; committed output freshness."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

PKG = Path(__file__).resolve().parents[2]
TOOLS = PKG / "tools" / "onboarding"
RENDER = [sys.executable, str(TOOLS / "render.py")]
VALIDATE = [sys.executable, str(TOOLS / "validate.py")]
MIGRATE = [sys.executable, str(TOOLS / "migrate_v1.py")]
sys.path.insert(0, str(TOOLS))
import onboarding_lib as lib

TREES = [(PKG / "onboarding/dev", "dev", PKG / "onboarding/rendered/dev"),
         (PKG / "examples/existing-environment/manifests/prod", "prod", PKG / "examples/existing-environment/rendered/prod")]


@pytest.mark.parametrize("manifests,env,rendered", TREES, ids=["lab-dev", "example-prod"])
def test_manifests_valid_strict_and_rendered_current(manifests, env, rendered):
    r = subprocess.run([*VALIDATE, "--manifests", str(manifests), "--env", env, "--strict"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
    r = subprocess.run([*RENDER, "render", "--manifests", str(manifests), "--env", env, "--out", str(rendered), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    for f in rendered.glob("*.json"):
        doc = json.loads(f.read_text())
        assert not lib.schema_errors(doc, lib.RENDERED_SCHEMA_FILE), f.name
        assert doc["package_version"] == (PKG / "VERSION").read_text().strip()
        assert "monitors" not in doc and "slos" not in doc, "the core package renders no monitoring content"


def test_rendered_tags_follow_the_policy():
    doc = json.loads((PKG / "onboarding/rendered/dev/hello-orders-api.json").read_text())
    assert doc["tags"]["owner"] == "orders_example.com" and doc["azure_tags"]["owner"] == "orders@example.com"
    assert {"env", "service", "team", "owner", "application", "domain", "tier", "region", "managed_by"} <= set(doc["tags"])
    assert "version" not in doc["tags"], "version is a deploy-time value"
    assert doc["telemetry"]["logs_route"] == "sidecar" and doc["telemetry"]["apm_mode"] == "policy"
    assert all(set(doc["tags"].items()) <= set(r["tags"].items()) for r in doc["resources"])


def test_lab_covers_every_enterprise_hello_service():
    services = {yaml.safe_load(p.read_text())["metadata"]["service"] for p in (PKG / "onboarding/dev").glob("*.yaml")}
    assert {"hello-frontend", "hello-bff", "hello-orders-api", "hello-catalog-api", "hello-inventory-api", "hello-durable",
            "hello-worker", "hello-partner-sim", "hello-jobs", "hello-functions"} <= services


def _manifest(**md) -> dict:
    meta = {"service": "svc", "team": "t1", "owner": "o@example.com", "env": "test", "application": "app", "domain": "d",
            "tier": "low", "region": "westeurope"}
    meta.update(md)
    return {"apiVersion": "observability/v2", "kind": "ServiceOnboarding", "metadata": meta,
            "spec": {"architecture": "aca", "runtime": "python",
                     "resources": [{"id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/containerApps/ca",
                                    "type": "Microsoft.App/containerApps", "role": "app"}]}}


def _run(tmp_path, doc, *extra):
    (tmp_path / "m").mkdir(exist_ok=True)
    (tmp_path / "m" / "svc.yaml").write_text(yaml.safe_dump(doc))
    return subprocess.run([*VALIDATE, "--manifests", str(tmp_path / "m"), "--strict", *extra], capture_output=True, text=True)


def test_missing_required_tag_fails(tmp_path):
    doc = _manifest()
    del doc["metadata"]["region"]
    r = _run(tmp_path, doc)
    assert r.returncode == 1 and "region" in r.stdout


def test_content_sections_are_notices_not_failures(tmp_path):
    doc = _manifest()
    doc["spec"]["monitors"] = {"disabled": ["x"]}
    doc["spec"]["notifications"] = {"default": ["r"]}
    r = _run(tmp_path, doc, "--routing", str(tmp_path / "nope.yaml"))
    assert r.returncode == 0, r.stdout
    assert "NOTICE" in r.stdout and "monitors" in r.stdout and "--routing is ignored" in r.stdout


def test_v1_manifest_rejected_with_migration_hint(tmp_path):
    doc = _manifest()
    doc["apiVersion"] = "observability/v1"
    r = _run(tmp_path, doc)
    assert r.returncode == 1 and "migrate_v1.py" in r.stdout


def test_bad_arm_id_fails(tmp_path):
    doc = _manifest()
    doc["spec"]["resources"][0]["id"] = "not-an-id"
    r = _run(tmp_path, doc)
    assert r.returncode == 1 and "ARM resource id" in r.stdout


def test_migrate_v1_drops_content_and_validates(tmp_path):
    v1 = PKG / "extras/content/onboarding/dev"
    out = tmp_path / "v2"
    r = subprocess.run([*MIGRATE, "--in", str(v1), "--out", str(out), "--region", "swedencentral"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    docs = [yaml.safe_load(p.read_text()) for p in out.glob("*.yaml")]
    assert docs and all(d["apiVersion"] == "observability/v2" and "monitors" not in d["spec"] for d in docs)
    r = subprocess.run([*VALIDATE, "--manifests", str(out), "--strict"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout


def test_references_resolution(tmp_path):
    (tmp_path / "c").mkdir()
    app_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/containerApps/a"
    (tmp_path / "c" / "deploy-x.json").write_text(json.dumps({"apps": {"a": {"id": app_id}}}))
    doc = _manifest()
    doc["spec"]["resources"] = [{"id": "${contract:deploy-x.apps.a.id}", "type": "Microsoft.App/containerApps", "role": "app"},
                                {"id": "${contract:deploy-y.missing}", "type": "Microsoft.Sql/servers/databases", "role": "db", "required": False}]
    (tmp_path / "m").mkdir()
    (tmp_path / "m" / "svc.yaml").write_text(yaml.safe_dump(doc))
    r = subprocess.run([*RENDER, "render", "--manifests", str(tmp_path / "m"), "--env", "test", "--out", str(tmp_path / "o"),
                        "--contracts-dir", str(tmp_path / "c")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    out = json.loads((tmp_path / "o" / "svc.json").read_text())
    assert [x["role"] for x in out["resources"]] == ["app"] and "dropped" in r.stderr
