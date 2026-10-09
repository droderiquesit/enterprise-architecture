"""Static wiring of the self-healing features into the two pipelines (what can be checked without Azure DevOps)."""

from __future__ import annotations

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def _read(rel):
    return (ROOT / rel).read_text()


def test_both_entries_have_heal_schedule_and_mode():
    from tools.changeset.select import auto_mode

    for entry in ("azure-pipelines.yml", "azure-pipelines.applications.yml"):
        doc = yaml.safe_load(_read(entry))
        heal = [s for s in doc["schedules"] if "heal" in s["displayName"].lower()]
        drift = [s for s in doc["schedules"] if "heal" not in s["displayName"].lower()]
        assert len(heal) == 1 and heal[0]["always"] is True and heal[0]["branches"]["include"] == ["main"]
        assert auto_mode("Schedule", heal[0]["displayName"]) == "heal"
        assert drift and all(auto_mode("Schedule", s["displayName"]) == "drift" for s in drift)
        modes = next(p for p in doc["parameters"] if p["name"] == "mode")["values"]
        assert "heal" in modes


def test_scripts_use_retry_lock_doctor_rollback():
    plan, apply, init = _read("pipelines/scripts/tf-plan.sh"), _read("pipelines/scripts/tf-apply.sh"), _read("pipelines/scripts/tf-init.sh")
    assert "tools/deploy/retry.py run" in init and "terraform" in init
    assert "retry.py run" in plan and "--ok-codes 0,2" in plan and "--lock-key" in plan
    assert "retry.py tf-apply" in apply and "--lock-key" in apply
    for s in (plan, apply):
        assert "lock_doctor.py claim" in s and "lock_doctor.py release" in s
    # rollback only for application deployment roots, never for infrastructure
    body = apply.split('if [[ "$root" == applications/deployments/* ]]; then', 1)
    assert len(body) == 2 and "rollback.sh" in body[1] and "rollback.sh" not in body[0].split("set -euo pipefail", 1)[1]
    assert "exit 1" in body[1]                       # a rolled-back stage still fails
    assert "remediate.py check" in plan
    rec = _read("pipelines/scripts/tf-record-failure.sh")
    assert "rolled_back" in rec and "QUARANTINED" in rec and "alert.sh" in rec


def test_preflight_and_cache_wiring():
    assert "preflight.sh" in _read("pipelines/scripts/tf-env.sh")
    setup = _read("pipelines/templates/steps-setup.yml")
    assert "Cache@2" in setup and "TOOL_CACHE_DIR" in setup and "versions.yaml" in setup
    install = _read("pipelines/scripts/install-tools.sh")
    assert "TOOL_CACHE_FALLBACK" in install
    # every install function still verifies its checksum after fetch()
    for tool in ("terraform", "gitleaks", "trivy", "syft", "helm", "kubeconform"):
        fn = install.split(f"install_{tool}() {{", 1)[1].split("\n}\n", 1)[0]
        assert "verify " in fn, tool


def test_heal_fanout_only_for_dev_schedules_and_records_in_templates():
    stages = _read("pipelines/templates/universal-stages.yml")
    assert "eq(parameters.environment, 'dev')" in stages and "heal_queue.py" in stages
    assert "contains(variables['Build.CronSchedule.DisplayName'], 'heal')" in stages
    plan = _read("pipelines/templates/terraform-plan.yml")
    assert "tf-record-failure.sh" in plan and "condition: failed()" in plan
    apply = _read("pipelines/templates/terraform-apply.yml")
    assert "health-${{ parameters.component }}-$(System.JobAttempt)" in apply
    assert "record.py verify" in _read("pipelines/templates/smoke.yml")
    ev = _read("pipelines/templates/evidence.yml")
    assert "ci_metrics.py summarize" in ev and "ci_metrics.py send" in ev and "DD_API_KEY=datadog-api-key?" in ev


def test_promotion_allows_heal_everywhere():
    doc = yaml.safe_load(_read("environments/promotion.yaml"))
    for e in doc["chains"][0]["environments"]:
        assert "heal" in e["allowed_modes"]
