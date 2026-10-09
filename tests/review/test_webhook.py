"""Service hook authentication, sanity and replay checks (recorded payload shapes from Microsoft Learn samples)."""

import base64
import datetime as dt
import json
from pathlib import Path

import pytest
from fake_ado import PROJECT_ID, REPO_ID

from tools.review.webhook import Allowlist, ReplayCache, WebhookRejected, check_auth, validate

PAYLOADS = Path(__file__).with_name("payloads")
SECRET = "s3cr3t-from-dsv"
ALLOW = Allowlist.from_settings(PROJECT_ID, REPO_ID)
NOW = dt.datetime(2026, 10, 9, 13, 5, tzinfo=dt.UTC)


def basic(user="eh-review", pw=SECRET):
    return "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()


def body(name="git.pullrequest.created", **over):
    d = json.loads((PAYLOADS / f"{name}.json").read_text())
    d.update(over)
    return json.dumps(d).encode()


def call(raw, header=None, replay=None, now=NOW, secrets=(SECRET,)):
    return validate(raw, basic() if header is None else header, username="eh-review", secrets=list(secrets), allow=ALLOW,
                    replay=replay or ReplayCache(), now=now)


@pytest.mark.parametrize("name", ["git.pullrequest.created", "git.pullrequest.updated", "git-pullrequest-comment-event",
                                  "git.pullrequest.updated.minimal"])
def test_valid_payloads(name):
    job = call(body(name))
    assert (job.repository_id, job.pull_request_id, job.project_id) == (REPO_ID, 7, PROJECT_ID)


@pytest.mark.parametrize("header", ["", "Bearer x", basic(pw="wrong"), basic(user="other"), basic(pw=SECRET + "x")])
def test_bad_signature_rejected(header):
    with pytest.raises(WebhookRejected) as e:
        call(body(), header=header)
    assert e.value.status == 401


def test_secret_rotation_accepts_previous():
    call(body(), header=basic(pw="old"), secrets=(SECRET, "old"))
    with pytest.raises(WebhookRejected) as e:
        check_auth(basic(), "eh-review", [])
    assert e.value.status == 503


def test_replay_rejected_by_age_and_by_event_id():
    with pytest.raises(WebhookRejected) as e:
        call(body(), now=NOW + dt.timedelta(minutes=30))
    assert e.value.status == 401 and "replay" in e.value.reason
    with pytest.raises(WebhookRejected):
        call(body(), now=NOW - dt.timedelta(minutes=10))     # from the future beyond skew
    cache = ReplayCache()
    job = call(body(), replay=cache)
    cache.add(job.event_id)
    with pytest.raises(WebhookRejected) as e:
        call(body(), replay=cache)
    assert e.value.status == 409


@pytest.mark.parametrize("over,status", [
    ({"publisherId": "evil"}, 400), ({"eventType": "git.push"}, 400), ({"id": "not-a-guid"}, 400),
    ({"resourceContainers": {"project": {"id": "00000000-0000-0000-0000-000000000000"}}}, 403),
])
def test_payload_sanity(over, status):
    with pytest.raises(WebhookRejected) as e:
        call(body(**over))
    assert e.value.status == status


def test_repository_allowlist_and_size():
    d = json.loads(body())
    d["resource"]["repository"]["id"] = "44444444-4444-4444-4444-444444444444"
    d["resource"]["url"] = ""
    with pytest.raises(WebhookRejected) as e:
        call(json.dumps(d).encode())
    assert e.value.status == 403
    with pytest.raises(WebhookRejected) as e:
        call(b"x" * (300 * 1024))
    assert e.value.status == 413


def test_auth_checked_before_parsing():
    with pytest.raises(WebhookRejected) as e:
        call(b"{not json", header=basic(pw="nope"))
    assert e.value.status == 401
