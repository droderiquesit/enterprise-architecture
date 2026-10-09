"""eh-pr-reviewer Function app: bindings, webhook -> queue, queue -> review against the fake Azure DevOps server."""

import base64
import datetime as dt
import json
from pathlib import Path

from conftest import REPO
from fake_ado import BOT_ID, ORG, PROJECT, PROJECT_ID, REPO_ID, FakeAdo
from pr_reviewer import handlers
from pr_reviewer.settings import Settings

from tools.review.ado import AdoClient
from tools.review.webhook import ReplayCache

SECRET = "unit-test-webhook-secret"
PAYLOADS = REPO / "tests/review/payloads"


class MemQueue:
    def __init__(self):
        self.sent = []

    def send(self, text, delay_seconds=0):
        self.sent.append((json.loads(text), delay_seconds))


class BusyLease:
    def acquire(self, key):
        return None

    def release(self, h):
        raise AssertionError("never acquired")


def settings(**over):
    env = {
        "ADO_ORGANIZATION": ORG,
        "ADO_PROJECT": PROJECT,
        "ADO_PROJECT_ID": PROJECT_ID,
        "ADO_REPOSITORY_IDS": REPO_ID,
        "ADO_REVIEWER_ID": BOT_ID,
        "WEBHOOK_SECRET": SECRET,
        "ADO_AUTH": "static",
        "REVIEW_RECHECK_SECONDS": "60",
    }
    env.update(over)
    return Settings.from_env(env)


def auth(pw=SECRET):
    return "Basic " + base64.b64encode(f"eh-review:{pw}".encode()).decode()


def event(name="git.pullrequest.created", pr_id=1, age_s=5):
    d = json.loads((PAYLOADS / f"{name}.json").read_text())
    d["createdDate"] = (dt.datetime.now(dt.UTC) - dt.timedelta(seconds=age_s)).isoformat().replace("+00:00", "Z")
    d["resource"]["pullRequestId"] = pr_id
    return json.dumps(d).encode()


def test_function_app_indexes_functions_with_expected_bindings(monkeypatch):
    import function_app

    fns = {f.get_function_name(): f for f in function_app.app.get_functions()}
    assert set(fns) == {"ado_webhook", "review_worker", "healthz", "readyz", "version"}
    hook = json.loads(fns["ado_webhook"].get_function_json())["bindings"][0]
    assert hook["type"] == "httpTrigger" and hook["route"] == "ado-webhook" and hook["methods"] == ["POST"] and hook["authLevel"] == "ANONYMOUS"
    q = json.loads(fns["review_worker"].get_function_json())["bindings"][0]
    assert q["type"] == "queueTrigger" and q["queueName"] == "%REVIEW_QUEUE_NAME%" and q["connection"] == "ReviewQueue"


def test_host_json_queue_settings():
    host = json.loads((Path(__file__).resolve().parents[1] / "host.json").read_text())
    qs = host["extensions"]["queues"]
    assert qs["messageEncoding"] == "none" and qs["batchSize"] == 1 and qs["maxDequeueCount"] == 5


def test_webhook_queues_valid_event_and_returns_fast():
    q, s, cache = MemQueue(), settings(), ReplayCache()
    status, body = handlers.webhook(event(), auth(), s, q, replay=cache)
    assert status == 202 and body["pullRequestId"] == 1
    msg, delay = q.sent[0]
    assert msg["job"]["repository_id"] == REPO_ID and msg["attempt"] == 0 and delay == 0
    # same delivery again (replay / ADO retry) -> acknowledged, not queued twice
    status2, body2 = handlers.webhook(event(), auth(), s, q, replay=cache)
    assert (status2, body2["status"], len(q.sent)) == (200, "duplicate", 1)


def test_webhook_rejects_bad_signature_and_stale_replay():
    q = MemQueue()
    assert handlers.webhook(event(), auth("wrong"), settings(), q, replay=ReplayCache())[0] == 401
    assert handlers.webhook(event(), None, settings(), q, replay=ReplayCache())[0] == 401
    assert handlers.webhook(event(age_s=3600), auth(), settings(), q, replay=ReplayCache())[0] == 401
    assert q.sent == []


def test_unresolved_dsv_secret_never_authenticates():
    s = settings(WEBHOOK_SECRET="dsv://eh/dev/pr-reviewer-webhook-secret#value")
    assert s.webhook_secrets == [] and "WEBHOOK_SECRET not resolved" in s.problems()
    status, _ = handlers.webhook(event(), auth("dsv://eh/dev/pr-reviewer-webhook-secret#value"), s, MemQueue(), replay=ReplayCache())
    assert status == 503
    assert handlers.ready(s)[0] == 503 and handlers.ready(settings())[0] == 200


def make_fake(tmp_path, files, build="approved"):
    import importlib.util

    spec = importlib.util.spec_from_file_location("review_conftest", REPO / "tests/review/conftest.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    repo = mod.make_repo(tmp_path / "repo")
    repo.branch("feature")
    repo.commit(files)
    ado = FakeAdo(repo.path).start()
    ado.add_pr(1, "main", "feature", build=build)
    return ado


def test_queue_job_end_to_end_approve(tmp_path, monkeypatch):
    monkeypatch.setenv("ADO_STATIC_TOKEN", "t")
    ado = make_fake(tmp_path, {"docs/guide.md": "# Guide\nbetter\n"})
    try:
        s = settings(ADO_BASE_URL=ado.url)
        q = MemQueue()
        handlers.webhook(event(), auth(), s, q, replay=ReplayCache())
        out = handlers.process_message(json.dumps(q.sent[0][0]), s, q, client=AdoClient(ado.url, ORG, PROJECT, lambda: "t", max_attempts=1))
        assert (out["decision"], out["vote"], out["status"], out["requeued"]) == ("approve", 10, "succeeded", False)
        assert ado.bot_vote(1) == 10
    finally:
        ado.stop()


def test_queue_job_pending_build_is_rechecked_later(tmp_path):
    ado = make_fake(tmp_path, {"docs/guide.md": "# Guide\nbetter\n"}, build="running")
    try:
        s = settings(ADO_BASE_URL=ado.url)
        q = MemQueue()
        job = {
            "job": {
                "event_id": "e",
                "event_type": "git.pullrequest.created",
                "project_id": PROJECT_ID,
                "repository_id": REPO_ID,
                "pull_request_id": 1,
                "created": "",
            },
            "attempt": 3,
        }
        out = handlers.process_message(json.dumps(job), s, q, client=AdoClient(ado.url, ORG, PROJECT, lambda: "t", max_attempts=1))
        assert out["status"] == "pending" and out["requeued"]
        assert q.sent[-1] == ({"job": job["job"], "attempt": 4}, 60)
        out2 = handlers.process_message(json.dumps(dict(job, attempt=30)), s, q, client=AdoClient(ado.url, ORG, PROJECT, lambda: "t", max_attempts=1))
        assert not out2["requeued"]  # bounded
    finally:
        ado.stop()


def test_queue_job_outside_allowlist_dropped_and_lock_contention_requeues():
    q, s = MemQueue(), settings()
    bad = {
        "job": {
            "event_id": "e",
            "event_type": "x",
            "project_id": PROJECT_ID,
            "repository_id": "44444444-4444-4444-4444-444444444444",
            "pull_request_id": 1,
            "created": "",
        }
    }
    assert handlers.process_message(json.dumps(bad), s, q, client=object())["state"] == "dropped"
    ok = {"job": dict(bad["job"], repository_id=REPO_ID), "attempt": 0}
    out = handlers.process_message(json.dumps(ok), s, q, lease=BusyLease(), client=object())
    assert out["state"] == "locked-requeued" and q.sent[-1][1] == 30
