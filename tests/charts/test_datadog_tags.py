"""Tag-policy plumbing of the hello-service chart (observability package 3.0.0, modules/tagging).

* every pod of the core-aks examples carries the policy's non-unified tags in the ad.datadoghq.com/tags annotation
  (Datadog Agent tag autodiscovery) and the same values in DD_TAGS / OTEL_RESOURCE_ATTRIBUTES
* the annotation values equal the env values (one tag set per workload, no drift between paths)
* Agent log collection mode renders the source/service log annotation instead of "[]"; SSI adds the admission label
"""

from __future__ import annotations

import json

import pytest
from chartlib import CHART, load_values, render

AKS_EXAMPLES = sorted(p for p in (CHART / "examples").glob("aks-*.yaml") if "cronjob" not in p.name)
REQUIRED = {"team", "owner", "application", "domain", "tier", "region", "managed_by"}


def pods(docs):
    return [d["spec"]["template"] for d in docs if d["kind"] == "Deployment"]


@pytest.mark.parametrize("values", AKS_EXAMPLES, ids=lambda p: p.stem)
def test_policy_tags_on_every_path(values, helm_bin):
    v = load_values(values)
    for pod in pods(render(values)):
        ann = json.loads(pod["metadata"]["annotations"]["ad.datadoghq.com/tags"])
        assert set(ann) >= REQUIRED, sorted(ann)
        env = {e["name"]: e.get("value") for e in pod["spec"]["containers"][0]["env"]}
        dd_tags = dict(t.split(":", 1) for t in env["DD_TAGS"].split(","))
        otel = dict(a.split("=", 1) for a in env["OTEL_RESOURCE_ATTRIBUTES"].split(","))
        for k, val in ann.items():
            assert dd_tags[k] == val, (k, dd_tags.get(k), val)
            assert otel[k] == val, (k, otel.get(k), val)
        assert otel["deployment.environment.name"] == env["DD_ENV"] == v["service"]["env"]
        assert otel["service.name"] == env["DD_SERVICE"] and otel["service.version"] == env["DD_VERSION"]
        labels = pod["metadata"]["labels"]
        assert labels["team"] == ann["team"] and labels["tier"] == ann["tier"]


def test_agent_log_collection_and_ssi_labels(helm_bin, tmp_path):
    v = load_values(CHART / "examples" / "aks-bff.yaml")
    v["telemetry"] = {**v["telemetry"], "disableAgentLogCollection": False, "agentLogSource": "csharp", "singleStepInstrumentation": True}
    pod = pods(render(v, tmp=tmp_path))[0]
    ann = pod["metadata"]["annotations"]
    assert json.loads(ann["ad.datadoghq.com/hello-bff.logs"]) == [{"source": "csharp", "service": "hello-bff"}]
    assert pod["metadata"]["labels"]["admission.datadoghq.com/enabled"] == "true"


def test_schema_rejects_bad_tag_key(helm_bin, tmp_path):
    from chartlib import template
    v = load_values(CHART / "examples" / "aks-bff.yaml")
    v["service"]["tags"] = {"Bad Key": "x"}
    res = template(v, tmp=tmp_path)
    assert res.returncode != 0 and "Bad Key" in res.stderr
