"""telemetry_verify.py against recorded Datadog API responses (no network)."""
import json
from pathlib import Path

import pytest

import telemetry_verify as tv

REC = Path(__file__).parent / "fixtures" / "datadog-api"


def load(name):
    return json.loads((REC / name).read_text())


class FakeDatadog:
    """Routes requests to recorded responses; can simulate eventual consistency and auth errors."""

    def __init__(self, marker_file="logs_marker_once.json", empty_first=0, auth_error=False, rum=True):
        self.calls = []
        self.marker_file = marker_file
        self.empty_first = empty_first
        self.auth_error = auth_error
        self.rum = rum

    def __call__(self, method, path, body, query):
        self.calls.append((method, path, json.dumps(body, sort_keys=True) if body else json.dumps(query, sort_keys=True)))
        if self.auth_error:
            raise tv.AuthError(f"{method} {path}: HTTP 403")
        if len(self.calls) <= self.empty_first:
            return load("empty.json")
        if path == "/api/v2/rum/events/search":
            return load("rum_resource_search.json") if self.rum else load("empty.json")
        if path == "/api/v2/spans/events/search":
            return load("spans_trace.json")
        if path == "/api/v2/logs/events/search":
            q = body["filter"]["query"]
            if "run-42" in q:
                return load(self.marker_file)
            return load("logs_pipeline.json")
        if path == "/api/v1/query":
            return load("metric_query.json")
        raise AssertionError(path)


class Clock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


ARGS = ["--env", "dev", "--frontend-service", "hello-frontend",
        "--journey-service", "hello-bff", "--journey-service", "hello-orders-api", "--journey-service", "hello-catalog-api",
        "--marker", "run-42", "--infra-metric", "azure.app_containerapps.requests",
        "--required-tag", "env", "--required-tag", "service", "--required-tag", "version",
        "--max-wait", "120", "--initial-interval", "5", "--max-interval", "20"]


def run(tmp_path, fake, extra=()):
    clock = Clock()
    ev = tmp_path / "evidence.json"
    rc = tv.main(ARGS + ["--evidence", str(ev)] + list(extra), transport=fake, sleep=clock.sleep, clock=clock)
    return rc, (json.loads(ev.read_text()) if ev.exists() else None), clock


def test_full_journey_passes_and_writes_evidence(tmp_path):
    rc, ev, _ = run(tmp_path, FakeDatadog())
    assert rc == 0
    status = {c["name"]: c["status"] for c in ev["checks"]}
    assert status == {n: "pass" for n in tv.ALL_CHECKS}
    apm = next(c for c in ev["checks"] if c["name"] == "apm_journey")
    assert apm["evidence"]["db_span_count"] == 1
    assert "DD_API_KEY" not in json.dumps(ev)


def test_trace_id_correlation_hex_and_decimal():
    hex32 = "844b6a2c7f1d2e3f8441d3d8fd171c9c"
    assert tv.hex_to_dd_decimal(hex32) == "9530131215405227164"
    assert tv.same_trace(hex32, "9530131215405227164")
    assert not tv.same_trace(hex32, "1")


def test_duplicate_logs_fail_immediately(tmp_path):
    rc, ev, clock = run(tmp_path, FakeDatadog(marker_file="logs_marker_twice.json"))
    assert rc == 1
    dup = next(c for c in ev["checks"] if c["name"] == "logs_no_duplicates")
    assert dup["status"] == "fail" and "DUPLICATES" in dup["details"] and dup["attempts"] == 1


def test_bounded_polling_with_backoff_then_success(tmp_path):
    rc, ev, clock = run(tmp_path, FakeDatadog(empty_first=2))
    assert rc == 0
    assert clock.sleeps[:2] == [5, 10]


def test_gives_up_after_max_wait(tmp_path):
    rc, ev, clock = run(tmp_path, FakeDatadog(rum=False), extra=["--checks", "rum_resource_trace"])
    assert rc == 1
    assert clock.t <= 120
    assert all(s <= 20 for s in clock.sleeps)
    rum = next(c for c in ev["checks"] if c["name"] == "rum_resource_trace")
    assert rum["status"] == "fail" and rum["attempts"] > 2


def test_missing_required_tag_fails(tmp_path):
    rc, ev, _ = run(tmp_path, FakeDatadog(), extra=["--required-tag", "team", "--checks", "required_tags"])
    assert rc == 1
    tags = next(c for c in ev["checks"] if c["name"] == "required_tags")
    assert any("team" in v["missing"] for v in tags["evidence"]["violations"])


def test_auth_error_exit_3(tmp_path):
    rc, _, _ = run(tmp_path, FakeDatadog(auth_error=True))
    assert rc == 3


def test_missing_keys_exit_2(tmp_path, monkeypatch):
    monkeypatch.delenv("DD_API_KEY", raising=False)
    monkeypatch.delenv("DD_APP_KEY", raising=False)
    assert tv.main(["--env", "dev", "--journey-service", "a", "--evidence", str(tmp_path / "e.json")]) == 2


def test_request_shapes_match_api(tmp_path):
    fake = FakeDatadog()
    run(tmp_path, fake)
    span_bodies = [json.loads(b) for m, p, b in fake.calls if p == "/api/v2/spans/events/search"]
    assert all(b["data"]["type"] == "search_request" and "filter" in b["data"]["attributes"] for b in span_bodies)
    log_bodies = [json.loads(b) for m, p, b in fake.calls if p == "/api/v2/logs/events/search"]
    assert all("filter" in b and "query" in b["filter"] for b in log_bodies)
    assert any(p == "/api/v1/query" and m == "GET" for m, p, b in fake.calls)
