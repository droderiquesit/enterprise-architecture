"""Self-healing selection: heal mode, held statuses (rolled_back / quarantined), drift auto-remediation, auto mode."""

from __future__ import annotations

import copy

import pytest
import yaml
from fixture_repo import SYNTHETIC_REGISTRY, commit_all, make_synthetic_repo, record_successful_deployment, write

from tools.changeset.ado import output_variables
from tools.changeset.registry import load_registry
from tools.changeset.select import auto_mode, select_all, select_deploy, select_heal, select_manual
from tools.changeset.store import LocalStore
from tools.changeset.trees import WorkTree


@pytest.fixture()
def lab(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    record_successful_deployment(repo, tmp_path / "records")
    return repo, LocalStore(tmp_path / "records")


def _set(records, cid, **fields):
    rec = records.get_json(f"dev/{cid}.json")
    rec.update(fields)
    records.put_json(f"dev/{cid}.json", rec)


def _env(repo, **self_healing):
    doc = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    doc["self_healing"] = {**(doc.get("self_healing") or {}), **self_healing}
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(doc, sort_keys=False))
    commit_all(repo, "self healing settings")


def test_auto_mode_heal_schedule():
    assert auto_mode("Schedule", "Platform heal (every 2 h, dev)") == "heal"
    assert auto_mode("Schedule", "Nightly platform drift detection (dev)") == "drift"
    assert auto_mode("Schedule", None) == "drift"
    assert auto_mode("PullRequest", "heal") == "pr"
    assert auto_mode("IndividualCI", "heal") == "deploy"


def test_heal_selects_only_failed_and_failed_verification(lab):
    repo, records = lab
    _set(records, "platform-db-sql", status="failed")
    _set(records, "deploy-core-aca", status="partial")
    _set(records, "deploy-frontend", verification={"status": "failed", "run_id": "1"})
    _set(records, "foundation-network", verification={"status": "passed", "run_id": "1"})
    doc = select_heal(repo, "dev", records)
    assert doc["mode"] == "heal"
    assert doc["summary"]["plan"] == ["deploy-core-aca", "deploy-frontend", "platform-db-sql"]
    assert set(doc["summary"]["apply_candidates"]) == set(doc["summary"]["plan"])
    assert doc["components"]["platform-db-sql"]["heal"] == "heal: last deployment failed"
    assert doc["components"]["deploy-frontend"]["heal"] == "heal: post-deployment verification failed"
    # consumers of a healed component are NOT dragged in (heal is narrow); artifacts of planned roots are resolved
    assert not doc["components"]["obs-monitoring"]["plan"]
    assert doc["components"]["svc-bff"]["resolve"]


def test_heal_skips_held_components(lab):
    repo, records = lab
    _set(records, "platform-db-sql", status="quarantined", quarantine={"reason": "3 consecutive failed deployments"})
    _set(records, "deploy-core-aca", status="rolled_back")
    _set(records, "platform-shared", status="canceled")
    doc = select_heal(repo, "dev", records)
    assert doc["summary"]["plan"] == ["platform-shared"]
    assert doc["held"] == ["deploy-core-aca", "platform-db-sql"]


def test_heal_disabled_selects_nothing(lab):
    repo, records = lab
    _env(repo, enabled=False)
    _set(records, "platform-db-sql", status="failed")
    doc = select_heal(repo, "dev", records)
    assert doc["summary"]["plan"] == []
    assert any("self_healing.enabled is false" in n for n in doc["notes"])


def test_held_status_blocks_deploy_until_new_commit(lab):
    repo, records = lab
    _set(records, "platform-db-sql", status="quarantined", quarantine={"reason": "3 consecutive failed deployments"})
    doc = select_deploy(repo, "dev", records)
    e = doc["components"]["platform-db-sql"]
    assert not e["plan"] and e["held"] == "quarantined"
    assert "platform-db-sql" in doc["held"]
    # a commit touching the component changes its deploy fingerprint and clears the hold
    write(repo, "platform/data/sql/main.tf", (repo / "platform/data/sql/main.tf").read_text() + "# fix\n")
    commit_all(repo, "fix sql")
    doc = select_deploy(repo, "dev", records)
    assert doc["components"]["platform-db-sql"]["plan"]
    assert "held" not in doc["components"]["platform-db-sql"]


def test_held_component_not_replanned_as_consumer(lab):
    repo, records = lab
    _set(records, "deploy-dbadapters", status="rolled_back")
    write(repo, "platform/data/cosmos/main.tf", "# changed\n")
    commit_all(repo, "cosmos change")
    doc = select_deploy(repo, "dev", records)
    assert doc["components"]["platform-db-cosmos"]["plan"]
    assert not doc["components"]["deploy-dbadapters"]["plan"]
    assert doc["components"]["deploy-dbadapters"]["held"] == "rolled_back"


def test_manual_run_clears_hold(lab):
    repo, records = lab
    _set(records, "platform-db-sql", status="quarantined")
    doc = select_manual(repo, "dev", ["platform-db-sql"], store=records)
    assert doc["components"]["platform-db-sql"]["plan"]
    assert doc["components"]["platform-db-sql"]["apply_candidate"]


def test_drift_auto_remediation_needs_registry_and_environment(tmp_path):
    reg = copy.deepcopy(SYNTHETIC_REGISTRY)
    for c in reg["components"]:
        if c["id"] == "obs-monitoring":
            c["drift"] = {"auto_remediate": True}
    repo = make_synthetic_repo(tmp_path, registry=reg)
    records = LocalStore(tmp_path / "records")
    record_successful_deployment(repo, tmp_path / "records")
    assert load_registry(WorkTree(repo)).get("obs-monitoring").drift_auto_remediate
    doc = select_all(repo, "dev", "drift", store=records)
    assert doc["components"]["obs-monitoring"]["remediate"] == "additive-only"
    assert doc["components"]["obs-monitoring"]["apply_candidate"]
    assert doc["drift_remediation"] == {"environment_allows": True, "components": ["obs-monitoring"]}
    others = [c for c, e in doc["components"].items() if e["plan"] and c != "obs-monitoring"]
    assert others and not any(doc["components"][c]["apply_candidate"] for c in others)
    reg_doc = load_registry(WorkTree(repo))
    out = output_variables(doc, reg_doc)
    assert out["apply_obs_monitoring"] == "true" and out["apply_platform_shared"] == "false"
    # environment does not opt in (test/prod default) -> report only
    _env(repo, drift_auto_remediate=False)
    doc = select_all(repo, "dev", "drift", store=records)
    assert "remediate" not in doc["components"]["obs-monitoring"]
    assert not doc["components"]["obs-monitoring"]["apply_candidate"]
    # quarantined components are never remediated
    _env(repo, drift_auto_remediate=True)
    _set(records, "obs-monitoring", status="quarantined")
    doc = select_all(repo, "dev", "drift", store=records)
    assert not doc["components"]["obs-monitoring"]["apply_candidate"]


def test_real_environments_remediation_policy():
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    for env, allowed in (("dev", True), ("test", False), ("prod", False)):
        sh = yaml.safe_load((root / f"environments/{env}/environment.yaml").read_text())["self_healing"]
        assert sh["drift_auto_remediate"] is allowed, env
    reg = load_registry(WorkTree(root))
    marked = sorted(c.id for c in reg if c.drift_auto_remediate)
    assert marked == ["foundation-governance", "foundation-secrets", "obs-azure-integration", "obs-diagnostics",
                      "obs-monitoring"]


def test_heal_cli_mode(lab, capsys):
    from tools.changeset.cli import main as cli

    repo, records = lab
    _set(records, "platform-db-sql", status="failed")
    rc = cli(["--repo", str(repo), "select", "--mode", "auto", "--build-reason", "Schedule",
              "--schedule-name", "Platform heal (every 2 h, dev)", "--env", "dev",
              "--records-dir", str(records.root), "--scope", "platform"])
    assert rc == 0
    out = capsys.readouterr()
    assert '"mode": "heal"' in out.out


def test_heal_in_promoted_environment_only_heals_the_same_code(lab, tmp_path):
    from fixture_repo import commit_all as _commit
    from test_scopes_promotion import _promotion_fixture

    repo, dev_records = lab
    _promotion_fixture(repo)
    test_records = LocalStore(tmp_path / "test-records")
    # test was promoted at this commit and platform-db-sql failed there
    promoted = select_deploy(repo, "test", test_records)
    for cid in ("platform-db-sql", "platform-shared"):
        e = promoted["components"][cid]
        test_records.put_json(f"test/{cid}.json", {"component": cid, "status": "failed", "deploy_fp": e["deploy_fp"],
                                                   "fp_parts": e["fp_parts"], "scope": e["scope"]})
    doc = select_heal(repo, "test", test_records)
    assert set(doc["summary"]["plan"]) == {"platform-db-sql", "platform-shared"}
    # main moved on: new sql code was never promoted -> not healed in test (needs a promotion), shared still is
    write(repo, "platform/data/sql/main.tf", "# sql v4\n")
    _commit(repo, "sql v4")
    doc = select_heal(repo, "test", test_records)
    assert doc["summary"]["plan"] == ["platform-shared"]
    assert any("platform-db-sql: not healed" in n and "promote again" in n for n in doc["notes"])
