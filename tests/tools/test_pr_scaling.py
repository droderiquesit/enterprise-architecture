"""Multi-developer scale helpers: deterministic sharding, versioning, PR time budget."""

from __future__ import annotations

import datetime as dt

import pytest

from tools.deploy import versioning
from tools.pipeline import shard
from tools.report import pr_budget


def test_shards_partition_the_suite_deterministically():
    ids = [f"tests/x/test_{i}.py::test_{j}" for i in range(20) for j in range(15)]
    parts = [shard.keep(ids, f"{i}/4") for i in range(1, 5)]
    assert sorted(sum(parts, [])) == sorted(ids)                      # union = whole suite
    assert all(not set(a) & set(b) for k, a in enumerate(parts) for b in parts[k + 1:])  # disjoint
    assert shard.keep(list(reversed(ids)), "2/4") == list(reversed(parts[1]))        # order independent
    assert all(len(p) > len(ids) / 8 for p in parts)                  # roughly balanced
    assert shard.keep(ids, None) == ids and shard.keep(ids, "1/1") == ids
    with pytest.raises(ValueError):
        shard.parse("5/4")


def test_versions(tmp_path):
    (tmp_path / "svc").mkdir()
    assert versioning.version("svc-a", "svc", "refs/heads/feature/x", "77", "abcdef1234", tmp_path) == "0.1.0+77.abcdef1"
    (tmp_path / "svc" / "VERSION").write_text("1.4.2\n")
    assert versioning.version("svc-a", "svc", "refs/heads/main", "78", "0123456789", tmp_path) == "1.4.2+78.0123456"
    assert versioning.version("svc-a", "svc", "refs/tags/svc-a-v1.4.2", "79", "0123456", tmp_path) == "1.4.2"
    assert versioning.version("svc-a", "svc", "refs/tags/svc-a-v9.9.9", "79", "0123456", tmp_path).startswith("1.4.2+")
    assert versioning.docker_tag("1.4.2+78.0123456") == "1.4.2-78.0123456"
    (tmp_path / "svc" / "VERSION").write_text("v1\n")
    with pytest.raises(ValueError):
        versioning.base_version("svc", tmp_path)


def test_pr_budget_summary():
    t0 = dt.datetime(2026, 10, 9, 10, 0, tzinfo=dt.timezone.utc)

    def at(m):
        return (t0 + dt.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.%f0Z")
    tl = {"records": [
        {"type": "Stage", "name": "Select", "startTime": at(0), "finishTime": at(1), "result": "succeeded"},
        {"type": "Job", "name": "validate (python)", "startTime": at(1), "finishTime": at(9), "result": "succeeded"},
        {"type": "Job", "name": "fmt", "startTime": at(1), "finishTime": at(2), "result": "succeeded"},
        {"type": "Task", "name": "ignored", "startTime": at(1), "finishTime": at(2)}]}
    doc = pr_budget.summarize(tl, 10, now=t0 + dt.timedelta(minutes=12))
    assert doc["wall_minutes"] == 12 and doc["over_budget"]
    assert doc["slowest_jobs"][0]["name"] == "validate (python)" and len(doc["jobs"]) == 2
    assert "OVER" in pr_budget.markdown(doc)
