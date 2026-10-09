"""Self-healing tools: retry classifier/backoff/intent, lock doctor, records (circuit breaker), rollback planning,
drift remediation guard, pipeline health metrics, heal fan-out, tool-cache fallback, pre-flight."""

from __future__ import annotations

import datetime as dt
import hashlib
import io
import json
import os
import random
import subprocess
import tarfile
from pathlib import Path

import pytest

from tools.changeset.store import LocalStore
from tools.deploy import lock_doctor, record, remediate, retry, rollback
from tools.report import ci_metrics

ROOT = Path(__file__).resolve().parents[2]
SAMPLES = sorted((Path(__file__).parent / "fixtures/errors").glob("*.txt"))


# ------------------------------------------------------------------ classifier
@pytest.mark.parametrize("sample", SAMPLES, ids=lambda p: p.stem)
def test_rules_classify_captured_samples(sample):
    kind, rule, _ = sample.stem.split("__")
    m = retry.classify(sample.read_text())
    assert (m.kind, m.rule) == (kind, rule)
    assert m.retryable == (kind in ("transient", "lock"))


def test_rules_file_is_well_formed():
    rules = retry.load_rules()
    ids = [r["id"] for s in ("permanent", "lock", "transient") for r in rules[s]]
    assert len(ids) == len(set(ids))
    assert {"throttled", "server-error", "state-lock", "authorization"} <= set(ids)
    assert len(SAMPLES) >= 15


def test_policy_from_registry_and_env(monkeypatch, tmp_path):
    p = retry.policy_for(None)
    assert (p.attempts, p.max_minutes) == (3, 20)
    monkeypatch.setenv("RETRY_ATTEMPTS", "5")
    assert retry.policy_for(None).attempts == 5


def test_backoff_is_exponential_bounded_with_jitter():
    p = retry.Policy(base_seconds=10, factor=2, max_backoff_seconds=60, jitter=0.0)
    r = random.Random(1)
    assert [p.backoff(i, r) for i in (1, 2, 3, 4, 5)] == [10, 20, 40, 60, 60]
    pj = retry.Policy(base_seconds=10, jitter=0.3)
    vals = [pj.backoff(1, random.Random(i)) for i in range(20)]
    assert all(7 <= v <= 13 for v in vals) and len(set(vals)) > 1


def _runner(outputs):
    calls = []

    def run(cmd):
        calls.append(cmd)
        return outputs[min(len(calls), len(outputs)) - 1]
    run.calls = calls
    return run


THROTTLED = (1, "Status=429 Code=\"TooManyRequests\"")
FORBIDDEN = (1, "Status=403 Code=\"AuthorizationFailed\"")


def test_run_with_retry_recovers_from_transient(tmp_path, monkeypatch):
    monkeypatch.setenv("RETRY_LOG", str(tmp_path / "r.jsonl"))
    run, sleeps = _runner([THROTTLED, THROTTLED, (0, "ok")]), []
    code, _out, events = retry.run_with_retry(["x"], label="init", component="c", runner=run, sleep=sleeps.append,
                                              policy=retry.Policy(attempts=3, jitter=0), rnd=random.Random(0))
    assert code == 0 and len(run.calls) == 3 and sleeps == [15, 30]
    assert [e["result"] for e in events] == ["retrying", "retrying", "recovered"]
    logged = [json.loads(line) for line in (tmp_path / "r.jsonl").read_text().splitlines()]
    assert logged[0]["rule"] == "throttled" and logged[-1]["result"] == "recovered"


def test_run_with_retry_fails_fast_on_permanent():
    run = _runner([FORBIDDEN])
    code, _o, events = retry.run_with_retry(["x"], label="plan", runner=run, sleep=lambda s: None)
    assert code == 1 and len(run.calls) == 1 and events[0]["result"] == "permanent"


def test_run_with_retry_unknown_is_permanent():
    run = _runner([(1, "something nobody has seen before")])
    _c, _o, events = retry.run_with_retry(["x"], label="plan", runner=run, sleep=lambda s: None)
    assert len(run.calls) == 1 and events[0]["class"] == "unknown"


def test_run_with_retry_respects_attempts_and_time_budget():
    run = _runner([THROTTLED])
    _c, _o, ev = retry.run_with_retry(["x"], label="l", runner=run, sleep=lambda s: None,
                                      policy=retry.Policy(attempts=2, jitter=0))
    assert len(run.calls) == 2 and ev[-1]["result"] == "exhausted"
    clock = iter([0, 0, 10_000]).__next__
    run = _runner([THROTTLED])
    _c, _o, ev = retry.run_with_retry(["x"], label="l", runner=run, sleep=lambda s: None, clock=clock,
                                      policy=retry.Policy(attempts=10, max_minutes=1, jitter=0))
    assert ev[-1]["result"] == "exhausted" and len(run.calls) <= 2


def test_run_with_retry_lock_hook():
    lock_out = (1, "Error acquiring the state lock\n  ID: abc\n")
    run = _runner([lock_out, (0, "")])
    code, _o, ev = retry.run_with_retry(["x"], label="plan", runner=run, sleep=lambda s: None, on_lock=lambda o: True,
                                        policy=retry.Policy(jitter=0))
    assert code == 0 and ev[0]["result"] == "lock-recovered"
    run = _runner([lock_out])
    code, _o, ev = retry.run_with_retry(["x"], label="plan", runner=run, sleep=lambda s: None, on_lock=lambda o: False)
    assert code == 1 and len(run.calls) == 1 and ev[0]["result"] == "lock-held"


def _plan(*changes):
    return {"resource_changes": [{"address": a, "mode": "managed", "change": {"actions": list(acts)}} for a, acts in changes]}


def test_intent_violations():
    reviewed = _plan(("a", ["create"]), ("b", ["update"]), ("c", ["delete", "create"]))
    assert retry.intent_violations(reviewed, _plan(("a", ["create"]), ("b", ["update"]))) == []
    assert retry.intent_violations(reviewed, _plan(("a", ["update"]))) == []      # created half-way -> now update
    probs = retry.intent_violations(reviewed, _plan(("b", ["delete"]), ("z", ["create"])))
    assert any("b: delete beyond" in p for p in probs) and any("z: create not in the reviewed plan" in p for p in probs)


def test_tf_apply_replans_and_continues_within_intent(monkeypatch, tmp_path):
    monkeypatch.setenv("RETRY_LOG", str(tmp_path / "r.jsonl"))
    reviewed = _plan(("a", ["create"]), ("b", ["create"]))
    shows = {"plan": reviewed, "replan.tfplan": _plan(("b", ["create"]))}
    seq = [(1, "StatusCode=503 ServiceUnavailable"), (2, ""), (0, "applied")]
    run = _runner(seq)
    rc = retry.tf_apply("c", "root", "plan", policy=retry.Policy(attempts=3, jitter=0), runner=run,
                        show=lambda p: shows[Path(p).name], sleep=lambda s: None)
    assert rc == 0
    assert run.calls[1][2] == "plan" and run.calls[2][-1].endswith("replan.tfplan")


def test_tf_apply_refuses_changes_outside_reviewed_plan(monkeypatch, tmp_path):
    monkeypatch.setenv("RETRY_LOG", str(tmp_path / "r.jsonl"))
    reviewed = _plan(("a", ["create"]))
    shows = {"plan": reviewed, "replan.tfplan": _plan(("a", ["create"]), ("x", ["delete"]))}
    run = _runner([(1, "context deadline exceeded"), (2, "")])
    rc = retry.tf_apply("c", "root", "plan", policy=retry.Policy(attempts=3, jitter=0), runner=run,
                        show=lambda p: shows[Path(p).name], sleep=lambda s: None)
    assert rc == 1 and len(run.calls) == 2      # never applied the re-plan
    events = [json.loads(line) for line in (tmp_path / "r.jsonl").read_text().splitlines()]
    assert events[-1]["result"] == "refused" and "x: delete" in events[-1]["violations"][0]


def test_tf_apply_permanent_failure_is_not_retried():
    run = _runner([FORBIDDEN])
    rc = retry.tf_apply("c", "root", "plan", runner=run, show=lambda p: _plan(), sleep=lambda s: None)
    assert rc == 1 and len(run.calls) == 1


# ----------------------------------------------------------------- lock doctor
LOCK = (ROOT / "tests/tools/fixtures/errors/lock__state-lock__lease.txt").read_text()
CREATED = dt.datetime(2026, 10, 9, 6, 12, 44, tzinfo=dt.timezone.utc)
ME = {"build_id": "200", "job_name": "Apply", "job_attempt": 1, "stage": "C_platform_shared"}


def test_parse_lock_info():
    info = lock_doctor.parse_lock_info(LOCK)
    assert info.id == "9f5c2e7a-1b2c-4d5e-8f90-123456789abc" and info.created == CREATED
    assert info.operation == "OperationTypeApply"


@pytest.mark.parametrize("status,age,expected", [
    (("inProgress", ""), 600, "wait"),           # running build: never broken, whatever the age
    (("cancelling", ""), 600, "wait"),
    (("completed", "failed"), 30, "break"),
    (("completed", "canceled"), 5, "wait"),       # too young to be provably stale
    (("unknown", ""), 60, "wait"),                # cannot read the holder -> wait
    (("unknown", ""), 500, "break"),              # older than any job timeout
])
def test_decide(status, age, expected):
    lock = lock_doctor.parse_lock_info(LOCK)
    holders = [{"build_id": "100", "job_name": "Apply", "job_attempt": 1, "stage": "C_platform_shared"}]
    action, _why = lock_doctor.decide(lock, holders, ME, CREATED + dt.timedelta(minutes=age), lambda b: status)
    assert action == expected
    if status[0] == "inProgress":
        assert action != "break"


def test_decide_own_previous_attempt_and_sibling_job():
    lock = lock_doctor.parse_lock_info(LOCK)
    me2 = dict(ME, job_attempt=2)
    prev = [dict(ME, job_attempt=1)]
    assert lock_doctor.decide(lock, prev, me2, CREATED + dt.timedelta(minutes=15), lambda b: ("inProgress", ""))[0] == "break"
    sibling = [dict(ME, job_name="Plan", stage="P_platform_shared")]
    assert lock_doctor.decide(lock, sibling, ME, CREATED + dt.timedelta(minutes=500), lambda b: ("inProgress", ""))[0] == "wait"
    assert lock_doctor.decide(lock, [], ME, CREATED + dt.timedelta(minutes=30), lambda b: ("x", ""))[0] == "wait"


def test_recover_breaks_stale_lock_with_audit(tmp_path, monkeypatch):
    monkeypatch.setenv("RETRY_LOG", str(tmp_path / "r.jsonl"))
    for k, v in (("BUILD_BUILDID", "200"), ("SYSTEM_JOBNAME", "Apply"), ("SYSTEM_JOBATTEMPT", "1"),
                 ("SYSTEM_STAGENAME", "C_platform_shared")):
        monkeypatch.setenv(k, v)
    store = LocalStore(tmp_path / "records")
    store.put_json("dev/_locks/platform-shared/100-Apply-1.json",
                   {"build_id": "100", "job_name": "Apply", "job_attempt": 1, "stage": "C_platform_shared"})
    broken = []
    ok = lock_doctor.recover(LOCK, env="dev", component="platform-shared", root="r", key="dev/platform-shared.tfstate",
                             store=store, account="st", status_fn=lambda b: ("completed", "failed"),
                             now_fn=lambda: CREATED + dt.timedelta(minutes=30), sleep=lambda s: None,
                             breaker=lambda root, lock, acct, key: broken.append(lock.id) or True)
    assert ok and broken == ["9f5c2e7a-1b2c-4d5e-8f90-123456789abc"]
    audits = store.list("dev/_audit/")
    assert len(audits) == 1 and store.get_json(audits[0])["holder"]["build_id"] == "100"
    assert store.list("dev/_locks/platform-shared/") == []
    assert json.loads((tmp_path / "r.jsonl").read_text().splitlines()[-1])["result"] == "lock-broken"


def test_recover_never_breaks_running_build_and_times_out(tmp_path, monkeypatch):
    monkeypatch.setenv("BUILD_BUILDID", "200")
    store = LocalStore(tmp_path / "records")
    store.put_json("dev/_locks/c/100-Apply-1.json", {"build_id": "100", "job_name": "Apply", "job_attempt": 1})
    sleeps, broken = [], []
    ok = lock_doctor.recover(LOCK, env="dev", component="c", root=None, key="k", store=store, account="a",
                             status_fn=lambda b: ("inProgress", ""), max_wait_minutes=10,
                             now_fn=lambda: CREATED + dt.timedelta(days=3), sleep=sleeps.append,
                             breaker=lambda *a: broken.append(1) or True)
    assert not ok and not broken
    assert sleeps[:3] == [30, 60, 120] and sum(sleeps) >= 600


def test_recover_returns_when_holder_releases(tmp_path, monkeypatch):
    monkeypatch.setenv("BUILD_BUILDID", "200")
    store = LocalStore(tmp_path / "records")
    key = "dev/_locks/c/100-Apply-1.json"
    store.put_json(key, {"build_id": "100", "job_name": "Apply", "job_attempt": 1})
    ok = lock_doctor.recover(LOCK, env="dev", component="c", root=None, key="k", store=store, account="a",
                             status_fn=lambda b: ("inProgress", ""), now_fn=lambda: CREATED,
                             sleep=lambda s: store.delete(key), breaker=lambda *a: pytest.fail("must not break"))
    assert ok


def test_break_lock_falls_back_to_lease_break():
    calls = []

    def runner(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 1 if cmd[0] == "terraform" else 0)
    info = lock_doctor.parse_lock_info(LOCK)
    assert lock_doctor.break_lock("root", info, "stacct", "dev/c.tfstate", runner=runner)
    assert calls[0][:3] == ["terraform", "-chdir=root", "force-unlock"]
    assert calls[1][:5] == ["az", "storage", "blob", "lease", "break"] and "--auth-mode" in calls[1]
    assert calls[1][calls[1].index("--auth-mode") + 1] == "login"


def test_claims_cli(tmp_path, monkeypatch):
    monkeypatch.setenv("BUILD_BUILDID", "7")
    monkeypatch.setenv("SYSTEM_JOBNAME", "Plan")
    store = tmp_path / "s"
    assert lock_doctor.main(["claim", "--env", "dev", "--component", "c", "--store", str(store)]) == 0
    assert (store / "dev/_locks/c/7-Plan-1.json").exists()
    assert lock_doctor.main(["release", "--env", "dev", "--component", "c", "--store", str(store)]) == 0
    assert not (store / "dev/_locks/c/7-Plan-1.json").exists()


# ------------------------------------------------------------ records/breaker
SEL = {"mode": "deploy", "components": {"c": {"kind": "terraform", "path": "p", "deploy_fp": "fp1", "fp_parts": {}}}}


def test_circuit_breaker_quarantines_after_threshold_and_success_resets():
    prev = None
    for i in range(2):
        prev = record.make_record("dev", "c", "failed", SEL, prev, "sha", str(i), threshold=3)
        assert prev["status"] == "failed" and prev["consecutive_failures"] == i + 1
    q = record.make_record("dev", "c", "partial", SEL, prev, "sha", "3", threshold=3, note="smoke")
    assert q["status"] == "quarantined" and q["last_status"] == "partial"
    assert "3 consecutive failed deployments" in q["quarantine"]["reason"]
    assert [h["status"] for h in q["history"]] == ["partial", "failed", "failed"]
    ok = record.make_record("dev", "c", "succeeded", SEL, q, "sha", "4", threshold=3)
    assert ok["status"] == "succeeded" and ok["consecutive_failures"] == 0 and "quarantine" not in ok
    rb = record.make_record("dev", "c", "rolled_back", SEL, ok, "sha", "5", threshold=3)
    assert rb["status"] == "rolled_back" and rb["consecutive_failures"] == 1 and rb["last_succeeded"]["run_id"] == "4"


def test_environment_thresholds():
    assert record.max_consecutive_failures("dev") == 3
    assert record.max_consecutive_failures("prod") == 2
    assert record.max_consecutive_failures("nope") == 3


def test_verify_op_records_smoke_outcome(tmp_path):
    store = LocalStore(tmp_path / "rec")
    store.put_json("dev/a.json", {"component": "a", "status": "succeeded"})
    store.put_json("dev/b.json", {"component": "b", "status": "succeeded"})
    res = tmp_path / "smoke.json"
    res.write_text(json.dumps({"components": {"a": {"status": "failed"}, "b": {"status": "passed"},
                                              "z": {"status": "failed"}}}))
    assert record.main(["verify", "--env", "dev", "--component", "*", "--store", str(tmp_path / "rec"),
                        "--smoke-results", str(res), "--run-id", "9"]) == 0
    assert store.get_json("dev/a.json")["verification"]["status"] == "failed"
    vb = store.get_json("dev/b.json")["verification"]
    assert vb == {"status": "passed", "run_id": "9", "at": vb["at"], "sources": {"smoke": {"status": "passed", "at": vb["at"]}}}
    assert store.get_json("dev/z.json") is None
    # telemetry of the same run failing makes the overall verification failed (smoke result kept)
    tel = tmp_path / "telemetry.json"
    tel.write_text(json.dumps({"components": {"b": {"status": "failed"}}}))
    assert record.main(["verify", "--env", "dev", "--component", "*", "--store", str(tmp_path / "rec"),
                        "--telemetry-results", str(tel), "--run-id", "9"]) == 0
    vb = store.get_json("dev/b.json")["verification"]
    assert vb["status"] == "failed" and set(vb["sources"]) == {"smoke", "telemetry"}
    # a newer run replaces older per-source results
    assert record.main(["verify", "--env", "dev", "--component", "b", "--store", str(tmp_path / "rec"),
                        "--smoke-results", str(res), "--run-id", "10"]) == 0
    vb = store.get_json("dev/b.json")["verification"]
    assert vb["status"] == "passed" and list(vb["sources"]) == ["smoke"] and vb["run_id"] == "10"


def test_telemetry_adapter_maps_journey_to_deployed_components(tmp_path):
    from tools.smoke import telemetry

    sel = {"components": {
        "deploy-core-aca": {"plan": True, "apply_candidate": True, "layer_name": "applications", "kind": "terraform"},
        "deploy-frontend": {"plan": True, "apply_candidate": True, "layer_name": "applications", "kind": "terraform"},
        "platform-shared": {"plan": True, "apply_candidate": True, "layer_name": "platform", "kind": "terraform"},
        "deploy-jobs": {"plan": True, "apply_candidate": False, "layer_name": "applications", "kind": "terraform"}}}
    argv = telemetry.verifier_args("dev", "datadoghq.eu", "ev.json")
    assert argv[0] == telemetry.VERIFIER and argv[argv.index("--site") + 1] == "datadoghq.eu"
    assert [argv[i + 1] for i, a in enumerate(argv) if a == "--journey-service"][0] == "hello-bff"
    assert "--selection" not in argv and "--out" not in argv     # the verifier's real interface
    fail = telemetry.results("dev", sel, {"result": "fail", "checks": [{"name": "apm_journey", "status": "fail"}]}, 1)
    assert fail["components"] == {"deploy-core-aca": {"status": "failed", "source": "telemetry"},
                                  "deploy-frontend": {"status": "failed", "source": "telemetry"}}
    assert fail["failed_checks"] == ["apm_journey"]
    ok = telemetry.results("dev", sel, {"result": "pass", "checks": []}, 0)
    assert {v["status"] for v in ok["components"].values()} == {"passed"}
    for rc in (2, 3):     # configuration / credential problems are not application failures
        assert telemetry.results("dev", sel, {}, rc)["components"] == {}
    # verifier exists and accepts exactly the arguments the adapter builds (argparse only, no network)
    import importlib.util
    spec = importlib.util.spec_from_file_location("tv", Path(__file__).resolve().parents[2] / telemetry.VERIFIER)
    tv = importlib.util.module_from_spec(spec)
    import sys
    sys.modules["tv"] = tv
    try:
        spec.loader.exec_module(tv)
    finally:
        sys.modules.pop("tv", None)
    tv.build_parser().parse_args(argv[1:])


# ------------------------------------------------------------------- rollback
ACA_NEW = {"architecture": "container-apps-consumption", "resource_group_name": "rg", "rollback": {"method": "traffic-shift"},
           "apps": {"hello-bff": {"name": "ca-bff", "revision_suffix": "r2"}, "hello-orders": {"name": "ca-ord", "revision_suffix": "r5"}}}
ACA_PREV = {"data": {"apps": {"hello-bff": {"name": "ca-bff", "revision_suffix": "r1"}, "hello-orders": {"name": "ca-ord", "revision_suffix": "r5"}}}}


def test_rollback_aca_traffic_shift():
    acts = rollback.plan_actions(ACA_NEW, ACA_PREV)
    assert [a["kind"] for a in acts] == ["aca-activate", "aca-traffic"]
    assert acts[1]["cmd"][-3:] == ["--revision-weight", "ca-bff--r1=100", "--only-show-errors"]


def test_rollback_slot_swap_only_when_swapped():
    new = {"rollback": {"method": "slot-swap"}, "deploy_steps": [
        {"kind": "webapp-zip", "app": "bff", "name": "app-bff", "resource_group": "rg", "slot": "staging", "package_sha256": "n"}]}
    prev = {"deploy_steps": [{"kind": "webapp-zip", "app": "bff", "name": "app-bff", "resource_group": "rg",
                              "slot": "staging", "package_sha256": "o"}]}
    assert rollback.plan_actions(new, prev, ["deployed bff"])[0]["kind"] == "none"     # never swapped: prod untouched
    acts = rollback.plan_actions(new, prev, ["swapped bff"])
    assert acts[0]["kind"] == "slot-swap-back" and acts[0]["idempotent"] is False
    assert acts[0]["cmd"][:5] == ["az", "webapp", "deployment", "slot", "swap"]


def test_rollback_flex_redeploys_previous_package_and_aks_helm():
    new = {"rollback": {"method": "redeploy-previous-package"},
           "deploy_steps": [{"kind": "functionapp-flex", "app": "durable", "package_sha256": "new"}]}
    prev = {"deploy_steps": [{"kind": "functionapp-flex", "app": "durable", "package_sha256": "old"}]}
    acts = rollback.plan_actions(new, prev, ["deployed durable"])
    assert acts[0]["kind"] == "redeploy-previous" and "{previous}" in acts[0]["cmd"]
    aks = {"rollback": {"method": "redeploy-previous-digest"},
           "cluster_id": "/subscriptions/s/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks1",
           "helm": {"releases": {"hello-bff": {"name": "hello-bff", "namespace": "hello"}}},
           "apps": {"hello-bff": {"image": "acr/bff@sha256:new"}}}
    acts = rollback.plan_actions(aks, {"apps": {"hello-bff": {"image": "acr/bff@sha256:old"}}})
    assert acts[0]["kind"] == "helm-rollback" and acts[0]["cmd"][:7] == ["az", "aks", "command", "invoke", "-g", "rg-aks", "-n"]
    assert "helm rollback hello-bff 0 -n hello --wait" in acts[0]["cmd"][-1]


def test_rollback_first_deployment_and_vm_commands():
    assert rollback.plan_actions({"rollback": {"method": "x"}}, None)[0]["kind"] == "none"
    vm = {"rollback": {"method": "reinstall-previous-package",
                       "commands": [{"kind": "vm-run-command", "resource_group": "rg", "vm": "vm1", "script": "rollback.sh"}]}}
    acts = rollback.plan_actions(vm, {"apps": {}})
    assert acts[0]["kind"] == "vm-run-command"


def test_rollback_execute_does_not_retry_swaps(monkeypatch, tmp_path):
    monkeypatch.setenv("RETRY_LOG", str(tmp_path / "r.jsonl"))
    calls = []
    acts = [{"kind": "slot-swap-back", "app": "a", "idempotent": False, "cmd": ["az", "swap"]},
            {"kind": "redeploy-previous", "app": "b", "idempotent": True, "cmd": ["bash", "deploy", "{previous}"]}]
    res = rollback.execute(acts, "/tmp/prev.json", runner=lambda c: calls.append(c) or 1, retry=False)
    assert [r["result"] for r in res] == ["failed(1)", "failed(1)"] and calls[1][-1] == "/tmp/prev.json"


def test_rollback_refuses_infrastructure(capsys):
    assert rollback.main(["run", "--env", "dev", "--component", "platform-shared", "--root", "platform/shared"]) == 0
    assert "never rolled back automatically" in capsys.readouterr().out


# ------------------------------------------------------------- drift guard
def test_remediation_guard():
    sel = {"mode": "drift", "components": {"c": {"remediate": "additive-only"}, "d": {}}}
    add = _plan(("a", ["update"]), ("b", ["create"]))
    assert remediate.decide(sel, "c", add)["remediate"] == "true"
    assert remediate.decide(sel, "c", _plan(("a", ["delete", "create"])))["remediate"] == "refused"
    assert remediate.decide(sel, "c", _plan(("a", ["delete"])))["remediate"] == "refused"
    assert remediate.decide(sel, "c", _plan())["remediate"] == "false"
    assert remediate.decide(sel, "d", add)["remediate"] == "n/a"
    assert remediate.decide(dict(sel, mode="deploy"), "c", add)["remediate"] == "n/a"


# ------------------------------------------------------------ health metrics
def test_health_summary_and_payloads(tmp_path):
    run = tmp_path / "run"
    (run / "selection").mkdir(parents=True)
    (run / "selection/selection.json").write_text(json.dumps({"mode": "heal", "scope": "platform", "held": ["q"], "components": {
        "a": {"plan": True, "heal": "heal: last deployment failed"}, "b": {"plan": True}, "q": {"plan": False}}}))
    for d in ("plan-a-1/health", "health-a-1", "plan-b-1/health"):
        (run / d).mkdir(parents=True)
    ev = [{"component": "a", "label": "terraform plan", "attempt": 1, "class": "transient", "rule": "throttled", "result": "retrying"},
          {"component": "a", "label": "terraform plan", "attempt": 2, "result": "recovered"}]
    (run / "plan-a-1/health/retries.jsonl").write_text("\n".join(json.dumps(e) for e in ev) + "\n")
    (run / "health-a-1/retries.jsonl").write_text(json.dumps({"component": "b", "label": "state lock", "result": "lock-broken"}) + "\n"
                                                  + json.dumps({"component": "b", "label": "rollback", "result": "rolled_back"}) + "\n")
    (run / "plan-b-1/health/remediation.json").write_text(json.dumps({"component": "b", "remediate": "refused", "destructive": ["x"]}))
    store = LocalStore(tmp_path / "rec")
    store.put_json("dev/a.json", {"status": "succeeded", "run_id": "42", "scope": "platform"})
    store.put_json("dev/b.json", {"status": "rolled_back", "run_id": "42", "scope": "platform"})
    store.put_json("dev/q.json", {"status": "quarantined", "run_id": "1", "scope": "platform", "quarantine": {"reason": "3 consecutive"}})
    doc = ci_metrics.summarize(run, "dev", "42", store, "platform")
    m = doc["metrics"]
    assert doc["healed"] == ["a"] and doc["rolled_back"] == ["b"] and doc["held"] == ["q"]
    assert (m["retries"], m["retries_recovered"], m["lock_recoveries"], m["quarantined"], m["drift_refused"]) == (1, 1, 1, 1, 1)
    assert m["failed_components"] == 1
    event, series = ci_metrics.datadog_payloads(doc, "lab-platform")
    assert event["alert_type"] == "error" and "env:dev" in event["tags"]
    names = {s["metric"] for s in series["series"]}
    assert {"pipeline.heal.healed", "pipeline.heal.quarantined", "pipeline.heal.lock_recoveries"} <= names
    assert all(s["type"] == 3 for s in series["series"])
    posted = []
    assert ci_metrics.send(doc, "datadoghq.eu", "k", poster=lambda u, b, h: posted.append((u, h)) or 202)
    assert [u for u, _ in posted] == ["https://api.datadoghq.eu/api/v1/events", "https://api.datadoghq.eu/api/v2/series"]
    assert posted[0][1] == {"DD-API-KEY": "k"}
    assert "Quarantined" in ci_metrics.markdown(doc)


def test_alert_work_item_and_datadog(monkeypatch):
    for k, v in (("SYSTEM_COLLECTIONURI", "https://dev.azure.com/org/"), ("SYSTEM_TEAMPROJECT", "lab"),
                 ("SYSTEM_ACCESSTOKEN", "t"), ("DD_API_KEY", "k")):
        monkeypatch.setenv(k, v)
    monkeypatch.setattr(ci_metrics, "notify_settings", lambda env: {"work_item": True, "work_item_type": "Bug", "datadog_event": True})
    wi_calls, dd = [], []

    def wi(url, body, headers):
        wi_calls.append((url, body, headers))
        return {"workItems": []} if "wiql" in url else {"id": 17}
    out = ci_metrics.alert("test", "c", "quarantine", "3 failures", "datadoghq.com",
                           poster=lambda u, b, h: dd.append(b) or 202, wi_poster=wi)
    assert out["work_item"] == 17 and out["datadog"] == 202
    assert "/_apis/wit/workitems/$Bug?api-version=7.1" in wi_calls[1][0]
    assert wi_calls[1][2]["Content-Type"] == "application/json-patch+json"
    assert dd[0]["alert_type"] == "error" and "component:c" in dd[0]["tags"]
    # an open work item with the same title is reused
    out = ci_metrics.alert("test", "c", "quarantine", "again", "", wi_poster=lambda u, b, h: {"workItems": [{"id": 5}]})
    assert out["work_item"] == 5


def test_monitor_archetypes_are_suggested():
    names = " ".join(m["name"] for m in ci_metrics.MONITOR_ARCHETYPES)
    for word in ("quarantined", "consecutive", "heal runs failing", "lock recovery"):
        assert word in names


# ------------------------------------------------------------------ fan-out
def test_heal_fanout_targets_and_requests():
    from tools.deploy import heal_queue

    assert heal_queue.targets(ROOT, 6) == ["test", "prod"]
    assert heal_queue.targets(ROOT, 8) == []
    assert heal_queue.targets(ROOT, 8, force=True) == ["test", "prod"]
    calls = []

    def http(method, url, body):
        calls.append((method, url, body))
        if "statusFilter" in url:
            return {"count": 1 if "env-prod" in url else 0}
        if method == "GET":
            return {"value": [{"sourceVersion": "abc123", "sourceBranch": "refs/heads/main"}]}
        return {"id": 99}
    res = heal_queue.fan_out(["test", "prod"], base="https://dev.azure.com/org", project="lab", definition="12", http=http)
    assert res[0] == {"env": "test", "action": "queued", "commit": "abc123", "run_id": 99}
    assert res[1]["action"] == "skipped"
    post = [c for c in calls if c[0] == "POST"][0]
    assert post[1].endswith("/lab/_apis/pipelines/12/runs?api-version=7.1")
    assert post[2]["templateParameters"] == {"environment": "test", "mode": "heal"}
    assert post[2]["resources"]["repositories"]["self"]["version"] == "abc123"


# ----------------------------------------------------- agent resilience (sh)
def _fake_helm_tarball(tmp_path: Path, version: str) -> tuple:
    tgz = tmp_path / f"helm-v{version}-linux-amd64.tar.gz"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        data = b"#!/bin/sh\necho fake-helm\n"
        info = tarfile.TarInfo("linux-amd64/helm")
        info.size, info.mode = len(data), 0o755
        tf.addfile(info, io.BytesIO(data))
    tgz.write_bytes(buf.getvalue())
    return tgz, hashlib.sha256(tgz.read_bytes()).hexdigest()


def _cache_name(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()[:16] + "-" + url.rsplit("/", 1)[1]


@pytest.mark.skipif(os.uname().machine not in ("x86_64",), reason="fixture tarball is amd64")
def test_install_tools_falls_back_to_verified_cache(tmp_path):
    v = "9.9.9"
    tgz, sha = _fake_helm_tarball(tmp_path, v)
    cache, bindir, fakebin = tmp_path / "cache", tmp_path / "bin", tmp_path / "fakebin"
    cache.mkdir(), fakebin.mkdir()
    url = f"https://get.helm.sh/helm-v{v}-linux-amd64.tar.gz"
    (cache / _cache_name(url)).write_bytes(tgz.read_bytes())
    (cache / _cache_name(url + ".sha256sum")).write_text(f"{sha}  helm-v{v}-linux-amd64.tar.gz\n")
    (fakebin / "curl").write_text("#!/bin/sh\necho 'curl: (6) Could not resolve host' >&2\nexit 6\n")
    (fakebin / "curl").chmod(0o755)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", TOOL_CACHE_DIR=str(cache), TOOLS_BIN=str(bindir),
               HELM_VERSION=v)
    env.pop("TF_BUILD", None)
    p = subprocess.run(["bash", str(ROOT / "pipelines/scripts/install-tools.sh"), "helm"], env=env,
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr + p.stdout
    assert "TOOL_CACHE_FALLBACK" in p.stderr and "fake-helm" in p.stdout
    # a tampered cached copy is rejected: the checksum is always verified
    (cache / _cache_name(url)).write_bytes(b"tampered")
    (bindir / "helm").unlink()
    p = subprocess.run(["bash", str(ROOT / "pipelines/scripts/install-tools.sh"), "helm"], env=env,
                       capture_output=True, text=True)
    assert p.returncode != 0 and "checksum mismatch" in p.stderr
    # no cache, no network: classified failure
    for f in cache.iterdir():
        f.unlink()
    p = subprocess.run(["bash", str(ROOT / "pipelines/scripts/install-tools.sh"), "helm"], env=env,
                       capture_output=True, text=True)
    assert p.returncode != 0 and "no cached copy" in p.stdout


def test_preflight_classifies_disk_failure(tmp_path):
    env = dict(os.environ, PREFLIGHT_MIN_DISK_MB="999999999", AGENT_WORKFOLDER=str(tmp_path))
    env.pop("LAB_ENV", None)
    p = subprocess.run(["bash", str(ROOT / "pipelines/scripts/preflight.sh"), "--no-az"], env=env, capture_output=True,
                       text=True, cwd=ROOT)
    assert p.returncode == 1 and "PREFLIGHT_FAIL class=disk" in p.stdout
    for line in p.stdout.splitlines():
        if line.startswith("PREFLIGHT_FAIL"):
            assert line.split()[1] in ("class=disk", "class=dns")
    p = subprocess.run(["bash", str(ROOT / "pipelines/scripts/preflight.sh")], env=dict(env, PREFLIGHT="skip"),
                       capture_output=True, text=True, cwd=ROOT)
    assert p.returncode == 0
