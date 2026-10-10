"""Tag policy, tag tools and Terraform/Python parity (package 3.0.0). Offline: recorded Datadog API fixtures only."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

PKG = Path(__file__).resolve().parents[2]  # observability/
REPO = PKG.parent
FIX = Path(__file__).parent / "fixtures"
TOOLS = PKG / "tools" / "tags"
sys.path.insert(0, str(TOOLS))

import check_coverage
import derive_from_monitors
from datadog_read import DatadogReader, ReadOnlyViolation
from query_tags import parse_query
from tag_policy import TagPolicy, normalize_value, schema_errors

PY = [sys.executable]


# ------------------------------------------------------------------ policies
def test_default_policies_are_valid():
    assert not schema_errors(yaml.safe_load((PKG / "config/tag-policy.yaml").read_text()))
    assert not schema_errors(yaml.safe_load((FIX / "contoso-tag-policy.yaml").read_text()))
    import jsonschema
    fleet = yaml.safe_load((PKG / "config/fleet-policy.yaml").read_text())
    jsonschema.Draft202012Validator(json.loads((PKG / "schemas/fleet-policy.v1.schema.json").read_text())).validate(fleet)


def test_policy_rejects_renamed_unified_key():
    doc = yaml.safe_load((PKG / "config/tag-policy.yaml").read_text())
    doc["keys"]["env"]["key"] = "environment"
    assert any("env" in e for e in schema_errors(doc))


def test_adr_required_keys_are_policy_required():
    """ADR-0001 section 7: env, service, version + team, owner, application, domain, tier, region, managed_by."""
    req = set(TagPolicy.load().required_keys())
    assert {"env", "service", "version", "team", "owner", "application", "domain", "tier", "region", "managed_by"} <= req
    assert "cost_center" not in req and "component" not in req


def test_lab_azure_tags_module_emits_every_required_key():
    """foundation/modules/tags (lab Azure resource tags) carries every required policy key, so the Datadog Azure
    integration imports the same keys onto the lab resources' metrics."""
    text = (REPO / "foundation/modules/tags/main.tf").read_text()
    block = text.split("tags = merge(", 1)[1]
    for key in TagPolicy.load().required_keys():
        assert f"\n    {key} " in block or f"\n    {key}=" in block.replace(" ", ""), key


def test_normalisation_matches_datadog_rules():
    assert normalize_value("Orders@Contoso.example") == "orders_contoso.example"
    assert normalize_value("  Retail  Banking!! ") == "retail_banking"
    assert normalize_value("4.2.0+build.7") == "4.2.0_build.7"
    assert normalize_value("a/b:c-d.e") == "a/b:c-d.e"


# ------------------------------------------------------------------ Terraform <-> Python parity
CASES = [
    ({"env": "Development", "service": "hello-orders-api", "version": "4.2.0+b7", "team": "orders", "owner": "Orders@Example.com",
      "application": "enterprise-hello", "domain": "orders", "tier": "critical", "region": "swedencentral"}, {"component": "x"}, None),
    ({"env": "prod", "service": "orders-api", "version": "1", "team": "orders", "owner": "o@c.example", "application": "orders",
      "domain": "commerce", "tier": "critical", "region": "westeurope"}, {}, FIX / "contoso-tag-policy.yaml"),
]


@pytest.mark.skipif(shutil.which("terraform") is None, reason="terraform not installed")
@pytest.mark.parametrize("identity,extra,policy", CASES, ids=["default", "contoso"])
def test_terraform_and_python_render_identically(identity, extra, policy, tmp_path):
    mod = PKG / "modules" / "tagging"
    data_dir = tmp_path / "tfdata"
    env = {"TF_DATA_DIR": str(data_dir)}
    import os
    full_env = {**os.environ, **env}
    subprocess.run(["terraform", f"-chdir={mod}", "init", "-backend=false", "-input=false"], check=True, capture_output=True, env=full_env)
    vars_ = {"identity": identity, "extra_tags": extra}
    if policy:
        vars_["policy"] = yaml.safe_load(Path(policy).read_text())
    vf = tmp_path / "v.tfvars.json"
    vf.write_text(json.dumps(vars_))
    expr = ("jsonencode({tags = local.tags, otel = local.otel, labels = local.k8s_labels, azure = local.azure_tags, "
            "dd = join(\",\", local.dd_list), missing = local.missing_required})")
    out = subprocess.run(["terraform", f"-chdir={mod}", "console", f"-var-file={vf}"], input=expr + "\n", capture_output=True,
                         text=True, check=True, env=full_env).stdout
    tf = json.loads(json.loads(out.strip()))
    py = TagPolicy.load(policy).render(identity, extra)
    assert tf["tags"] == py["tags"]
    assert tf["otel"] == py["otel_resource_attributes"]
    assert tf["labels"] == py["k8s_labels"]
    assert tf["azure"] == py["azure_tags"]
    assert tf["dd"] == py["dd_tags"]
    assert tf["missing"] == py["missing_required"]


# ------------------------------------------------------------------ query parsing
@pytest.mark.parametrize("query,mtype,expect", [
    ("avg(last_5m):sum:trace.http.request.errors{env:prod,service:orders-api} by {host,availability-zone} > 5", "query alert",
     {("env", "prod", "filter"), ("service", "orders-api", "filter"), ("host", None, "group_by")}),
    ('logs("service:orders env:prod status:error -team:qa @http.status_code:500").index("*").rollup("count").by("service").last("5m") > 10',
     "log alert", {("service", "orders", "filter"), ("env", "prod", "filter"), ("team", "qa", "negated"), ("service", None, "group_by")}),
    ("avg(last_5m):avg:k8s.cpu{kube_namespace IN (a,b) AND NOT tier:low AND !owner:x} > 1", "metric alert",
     {("kube_namespace", "a", "filter"), ("kube_namespace", "b", "filter"), ("tier", "low", "negated"), ("owner", "x", "negated")}),
    ('"http.can_connect".over("env:prod","team:orders").exclude("host:c").by("host").last(3).count_by_status()', "service check",
     {("env", "prod", "filter"), ("team", "orders", "filter"), ("host", "c", "negated"), ("host", None, "group_by")}),
    ('rum("env:prod service:web @type:error").rollup("count").last("15m") > 10', "rum alert", {("env", "prod", "filter"), ("service", "web", "filter")}),
    ("avg(last_5m):avg:system.cpu.user{env:$env.value,service:x} > 1", "metric alert", {("service", "x", "filter"), ("env", None, "filter")}),
])
def test_query_parsing(query, mtype, expect):
    ex = parse_query(query, mtype)
    got = {(u.key, u.value, u.usage) for u in ex.uses if not u.attribute}
    assert expect <= got, got
    assert not ex.unparsed
    if "@" in query:
        assert any(u.attribute for u in ex.uses), "facets are attributes, not tags"


def test_composite_has_no_tags():
    assert parse_query("101 && 102", "composite").uses == []


# ------------------------------------------------------------------ read-only client
def test_reader_refuses_writes(tmp_path):
    r = DatadogReader(fixtures=FIX / "org-contoso")
    for method, path in (("POST", "/api/v1/monitor"), ("PUT", "/api/v1/monitor/1"), ("DELETE", "/api/v1/slo/x"), ("PATCH", "/api/v2/x")):
        with pytest.raises(ReadOnlyViolation):
            r.request(method, path)
    r.request("POST", "/api/v2/logs/events/search", body={"filter": {"query": "x"}})  # search = read


def test_reader_pages_monitors(tmp_path):
    (tmp_path / "monitors.json").write_text(json.dumps({"pages": [[{"id": 1, "query": "", "type": "query alert"}],
                                                                  [{"id": 2, "query": "", "type": "query alert"}], []]}))
    r = DatadogReader(fixtures=tmp_path)
    assert [m["id"] for m in r.monitors(page_size=1)] == [1, 2]


# ------------------------------------------------------------------ derive_from_monitors
def test_derive_report_from_recorded_org(tmp_path):
    out = tmp_path / "req.json"
    md = tmp_path / "req.md"
    assert derive_from_monitors.main(["--fixtures", str(FIX / "org-contoso"), "--out-json", str(out), "--out-md", str(md)]) == 0
    rep = json.loads(out.read_text())
    assert rep["monitors_scanned"] == 11 and rep["slos_scanned"] == 3
    assert {"env", "service", "team", "tier", "domain", "application", "business_unit", "environment"} <= set(rep["required_keys"])
    assert "host" not in rep["required_keys"] and rep["keys"]["host"]["classification"] == "platform"
    assert rep["keys"]["env"]["values"] == ["production"]
    assert rep["keys"]["tier"]["negated_values"] == ["low"]
    assert rep["keys"]["owner"]["filtered_by"] == 0 and rep["keys"]["owner"]["monitor_tag_values"] == ["orders@contoso.example"]
    assert "@http.status_code" in rep["attributes"]
    assert not rep["unparsed"], rep["unparsed"]
    sugg = {s["key"]: s["suggestion"] for s in rep["suggestions"]}
    assert "alias of 'env'" in sugg["environment"]
    assert "Required keys" in md.read_text()


# ------------------------------------------------------------------ check_coverage
def _render(manifests: Path, env: str, out: Path, policy: Path | None = None):
    cmd = [*PY, str(PKG / "tools/onboarding/render.py"), "render", "--manifests", str(manifests), "--env", env, "--out", str(out)]
    if policy:
        cmd += ["--tag-policy", str(policy)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_coverage_static_lab_and_example_pass_policy():
    for d in (PKG / "onboarding/rendered/dev", PKG / "examples/existing-environment/rendered/prod"):
        assert check_coverage.main(["--rendered", str(d), "--out-json", "-"]) == 0


def test_coverage_against_existing_monitors_fails_then_passes_with_customer_policy(tmp_path, capsys):
    req = tmp_path / "req.json"
    derive_from_monitors.main(["--fixtures", str(FIX / "org-contoso"), "--out-json", str(req)])
    example = PKG / "examples/existing-environment"
    out = tmp_path / "cov.json"
    rc = check_coverage.main(["--rendered", str(example / "rendered/prod"), "--requirements", str(req), "--out-json", str(out)])
    rep = json.loads(out.read_text())
    assert rc == 1
    types = {(g["type"], g["key"]) for g in rep["gaps"] if g.get("required")}
    assert ("value_mismatch", "env") in types and ("missing_monitor_key", "business_unit") in types and ("missing_monitor_key", "environment") in types
    # the customer policy (alias environment, env value_map prod -> production, static business_unit) closes every gap
    rendered = tmp_path / "rendered"
    _render(example / "manifests/prod", "prod", rendered, FIX / "contoso-tag-policy.yaml")
    rc = check_coverage.main(["--rendered", str(rendered), "--requirements", str(req), "--policy", str(FIX / "contoso-tag-policy.yaml"),
                              "--out-json", str(out)])
    rep = json.loads(out.read_text())
    assert rc == 0, [g for g in rep["gaps"] if g.get("required")]
    orders = json.loads((rendered / "orders-api.json").read_text())
    assert orders["tags"]["env"] == "production" and orders["tags"]["environment"] == "production" and orders["tags"]["business_unit"] == "retail"


def test_coverage_live_mode_with_recorded_responses(tmp_path):
    rendered = tmp_path / "rendered"
    _render(PKG / "examples/existing-environment/manifests/prod", "prod", rendered, FIX / "contoso-tag-policy.yaml")
    out = tmp_path / "live.json"
    rc = check_coverage.main(["--rendered", str(rendered), "--policy", str(FIX / "contoso-tag-policy.yaml"), "--live",
                              "--fixtures", str(FIX / "live-prod"), "--require-data", "--out-json", str(out), "--out-md", str(tmp_path / "live.md")])
    rep = json.loads(out.read_text())
    by_type = {}
    for g in rep["gaps"]:
        by_type.setdefault(g["type"], []).append(g)
    # orders-api: complete; orders-web: owner missing (observed gap); telemetry-pipeline / azure-platform-logs: no data
    assert rc == 1
    assert {g["service"] for g in by_type["no_data"]} == {"telemetry-pipeline", "azure-platform-logs"}
    assert [g["service"] for g in by_type["observed_tag_gap"]] == ["orders-web"] and "owner" in by_type["observed_tag_gap"][0]["missing"]
    assert rep["observed"]["events_per_service"]["orders-api"] == 2
    assert "no_data" in (tmp_path / "live.md").read_text()


# ------------------------------------------------------------------ telemetry_verify uses the policy
def test_telemetry_verify_required_tags_come_from_the_policy():
    sys.path.insert(0, str(PKG / "tools/verify"))
    import telemetry_verify as tv

    args = tv.build_parser().parse_args(["--env", "dev", "--journey-service", "hello-bff",
                                         "--expected-tags-dir", str(PKG / "onboarding/rendered/dev")])
    required, expected, pipeline_tag = tv.policy_defaults(args)
    assert set(required) >= {"env", "service", "version", "team", "owner", "region", "managed_by"}
    assert expected["hello-bff"]["team"] == "web"
    assert pipeline_tag == "telemetry.pipeline:observability-pipelines"
