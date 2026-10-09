"""Content tests: archetype merge precedence, rendering, validation, references, committed output freshness."""
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

import onboarding_lib as lib

PKG = Path(__file__).resolve().parents[2]
ARCH = PKG / "archetypes"
FIX = Path(__file__).parent / "fixtures"
RENDER = [sys.executable, str(PKG / "tools/onboarding/render.py")]
VALIDATE = [sys.executable, str(PKG / "tools/onboarding/validate.py")]


def manifest(**over):
    base = {
        "apiVersion": "observability/v1", "kind": "ServiceOnboarding",
        "metadata": {"service": "svc", "team": "t1", "owner": "o@example.com", "env": "test",
                     "runbook_url": "https://rb.example.com/svc"},
        "spec": {"architecture": "aca", "telemetry": {"profile": "http-api"},
                 "resources": [{"id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/containerApps/ca", "type": "Microsoft.App/containerApps", "role": "app"}],
                 "notifications": {"default": ["r1"], "critical": ["r2"]}},
    }
    return lib.deep_merge(base, over)


def render(doc, env="test", refs=None):
    arch = lib.ArchetypeSet.load(ARCH)
    return lib.render_manifest(doc, "t/svc.yaml", b"x", arch, env, "9.9.9", refs).data


# ------------------------------------------------------------------ merge semantics
def test_deep_merge_replaces_lists_and_appends_with_plus():
    a = {"x": {"l": [1, 2], "k": 1}, "t": ["a"]}
    b = {"x": {"l": [3]}, "t+": ["b"]}
    assert lib.deep_merge(a, b) == {"x": {"l": [3], "k": 1}, "t": ["a", "b"]}
    assert a == {"x": {"l": [1, 2], "k": 1}, "t": ["a"]}, "inputs must not be mutated"


def test_deep_merge_plus_on_non_list_fails():
    with pytest.raises(lib.OnboardingError):
        lib.deep_merge({"t": "s"}, {"t+": ["x"]})


def test_layer_order_global_platform_resource_profile():
    arch = lib.ArchetypeSet.load(ARCH)
    doc = manifest(spec={"resources": [
        {"id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Sql/servers/s/databases/d", "type": "Microsoft.Sql/servers/databases", "role": "db"}],
        "telemetry": {"profile": "durable-workflow"}})
    names = [n for n, _ in arch.layers_for(doc)]
    assert names == ["global-defaults", "platform/aca", "platform/database-sql", "profiles/http-api", "profiles/durable-workflow"]


def test_precedence_manifest_over_profile_over_platform_over_global():
    # global: error_log_threshold=50 ; http-api profile: error_rate_pct=5 ; manifest params override both.
    d = render(manifest())
    assert d["monitors"]["logs.error_spike"]["thresholds"]["critical"] == 50
    assert d["monitors"]["apm.error_rate"]["thresholds"]["critical"] == 5
    d = render(manifest(spec={"monitors": {"params": {"error_rate_pct": 7, "error_log_threshold": 9}}}))
    assert d["monitors"]["apm.error_rate"]["thresholds"]["critical"] == 7
    assert d["monitors"]["apm.error_rate"]["query"].endswith("> 7")
    assert d["monitors"]["logs.error_spike"]["thresholds"]["critical"] == 9
    # explicit monitor override beats params
    d = render(manifest(spec={"monitors": {"params": {"error_rate_pct": 7}, "overrides": {"apm.error_rate": {"thresholds": {"critical": 11}}}}}))
    assert d["monitors"]["apm.error_rate"]["query"].endswith("> 11")


def test_platform_default_logs_route_overridden_by_profile_and_manifest():
    assert render(manifest())["telemetry"]["logs"]["route"] == "sidecar"           # platform/aca
    d = render(manifest(spec={"telemetry": {"profile": "frontend"}, "architecture": "swa", "resources": []}))
    assert d["telemetry"]["logs"]["route"] == "none"                                 # profile frontend
    d = render(manifest(spec={"telemetry": {"profile": "http-api", "logs": {"route": "eventhub"}}}))
    assert d["telemetry"]["logs"]["route"] == "eventhub"                              # manifest


def test_role_override_and_disabled_glob():
    d = render(manifest(spec={"monitors": {"overrides": {"aca.restarts@app": {"priority": 1}}, "disabled": ["apm.*"]}}))
    assert d["monitors"]["aca.restarts@app"]["priority"] == 1
    assert not [k for k in d["monitors"] if k.startswith("apm.")]


def test_no_data_only_for_always_on_services():
    assert "apm.no_traffic" in render(manifest())["monitors"]
    d = render(manifest(spec={"idle_behavior": {"scale_to_zero": True}}))
    assert "apm.no_traffic" not in d["monitors"]


def test_functions_platform_defaults_to_scale_to_zero():
    d = render(manifest(spec={"architecture": "functions", "resources": []}))
    assert d["idle_behavior"]["scale_to_zero"] is True
    assert "apm.no_traffic" not in d["monitors"]


def test_unknown_profile_and_placeholder_fail():
    with pytest.raises(lib.OnboardingError):
        render(manifest(spec={"telemetry": {"profile": "nope"}}))
    with pytest.raises(lib.OnboardingError):
        lib.expand("[[params.missing]]", {"params": {}}, "x")


def test_resource_placeholders_left_for_terraform():
    d = render(manifest())
    q = d["monitors"]["aca.http_5xx_ratio@app"]["query"]
    assert "[[resource.scope]]" in q and "[[" not in q.replace("[[resource.scope]]", "")


def test_notifications_fallback_to_default_and_severity_routing():
    d = render(manifest())
    assert d["monitors"]["apm.error_rate"]["notify"]["alert"] == ["r2"]     # severity critical
    assert d["monitors"]["apm.http_5xx"]["notify"]["alert"] == ["r1"]       # warning -> default


def test_burn_rate_clamped_for_low_targets():
    diag = lib.Diagnostics()
    arch = lib.ArchetypeSet.load(ARCH)
    doc = manifest(spec={"slos": [{"name": "a", "type": "availability", "target": 95, "timeframe": "90d"}]})
    d = lib.render_manifest(doc, "t", b"x", arch, "test", "1", None, diag).data
    thr = [b["threshold"] for b in d["slos"][0]["burn_rate_alerts"]]
    assert max(thr) <= 18.0 and diag.warnings


# ------------------------------------------------------------------ references
def test_references_resolve_drop_optional_and_fail_required(tmp_path):
    (tmp_path / "platform-messaging").mkdir()
    (tmp_path / "platform-messaging" / "v1.json").write_text(json.dumps({
        "contract": "platform-messaging", "version": "1.0.0", "environment": "test",
        "produced_by": {"component": "platform-messaging", "commit": "abc"},
        "data": {"namespace_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/sb"}}))
    refs = lib.flatten_contracts(tmp_path)
    assert refs["platform-messaging.namespace_id"].endswith("/namespaces/sb")
    doc = manifest(spec={"resources+": [
        {"id": "${contract:platform-messaging.namespace_id}", "type": "Microsoft.ServiceBus/namespaces", "role": "bus"},
        {"id": "${contract:platform-db-redis.cache.id}", "type": "Microsoft.Cache/redisEnterprise", "role": "cache", "required": False}]})
    d = render(doc, refs=refs)
    roles = [r["role"] for r in d["resources"]]
    assert roles == ["app", "bus"]
    assert "queue.backlog@bus" in d["monitors"] and not [k for k in d["monitors"] if k.endswith("@cache")]
    doc["spec"]["resources"][2]["required"] = True
    with pytest.raises(lib.OnboardingError):
        render(doc, refs=refs)


def test_literal_ids_must_be_arm_ids():
    with pytest.raises(lib.OnboardingError):
        render(manifest(spec={"resources": [{"id": "not-an-id", "type": "Microsoft.App/containerApps", "role": "app"}]}))


# ------------------------------------------------------------------ committed content
LAB_ENVS = sorted(p.name for p in (PKG / "onboarding").iterdir() if p.is_dir() and p.name not in ("rendered", "routing"))


@pytest.mark.parametrize("env", LAB_ENVS)
def test_lab_manifests_valid_strict(env):
    r = subprocess.run(VALIDATE + ["--manifests", str(PKG / "onboarding" / env), "--env", env,
                                   "--routing", str(PKG / "onboarding/routing" / f"{env}.yaml"), "--strict"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("env", LAB_ENVS)
def test_lab_rendered_output_is_current(env):
    r = subprocess.run(RENDER + ["render", "--manifests", str(PKG / "onboarding" / env), "--env", env,
                                 "--out", str(PKG / "onboarding/rendered" / env), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@pytest.mark.parametrize("env", ["test", "strict"])
def test_module_fixture_render_is_current(env):
    fx = PKG / "modules/onboarding/tests/fixtures"
    r = subprocess.run(RENDER + ["render", "--manifests", str(fx / "manifests"), "--env", env,
                                 "--out", str(fx / "rendered" / env), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def all_rendered():
    for p in sorted((PKG / "onboarding/rendered").glob("*/*.json")):
        yield p.name, json.loads(p.read_text())
    for p in sorted((PKG / "modules/onboarding/tests/fixtures/rendered").glob("*/*.json")):
        yield p.name, json.loads(p.read_text())


def test_every_monitor_has_runbook_notification_and_matching_threshold():
    count = 0
    for name, doc in all_rendered():
        for key, m in doc["monitors"].items():
            count += 1
            assert re.search(r"Runbook: https?://\S+#\S+", m["message"]), (name, key)
            assert m["notify"]["alert"], (name, key)
            crit = lib._fmt(m["thresholds"]["critical"])
            assert m["query"].rstrip().endswith(crit), (name, key, m["query"])
            assert any(t.startswith("team:") for t in m["tags"]) and "managed_by:observability-package" in m["tags"]
            assert "troubleshooting" in m["message"].lower()
        for slo in doc["slos"]:
            for b in slo["burn_rate_alerts"]:
                assert "Runbook: http" in b["message"] and b["notify"]["alert"]
    assert count > 100


def test_metric_names_are_documented():
    verified = {ln.strip() for ln in (FIX / "verified-metrics.txt").read_text().splitlines() if ln and not ln.startswith("#")}
    app_metric_prefixes = ("hello.workflow.", "app.workflow.")  # application custom metrics (documented contract)
    pattern = re.compile(r"(?:sum|avg|max|min|p\d\d|count):([a-z_][a-z0-9_.]*)\{")
    seen = set()
    for _, doc in all_rendered():
        for m in doc["monitors"].values():
            for metric in pattern.findall(m["query"]):
                seen.add(metric)
    for metric in sorted(seen):
        if metric.startswith("trace."):
            assert re.fullmatch(r"trace\.[a-z0-9_.]+?(\.hits|\.errors|\.hits\.by_http_status)?", metric), metric
            continue
        if metric.startswith(app_metric_prefixes):
            continue
        assert metric in verified, f"metric not in verified documentation list: {metric}"
    assert any(m.startswith("azure.") for m in seen)


def test_archetype_files_match_schema_and_names():
    lib.ArchetypeSet.load(ARCH)  # raises on schema errors / name mismatch


def test_validate_cli_exit_codes(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text(yaml.safe_dump(manifest(spec={"telemetry": {"profile": "http-api", "logs": {"route": "nope"}}})))
    r = subprocess.run(VALIDATE + ["--manifests", str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 1 and "ERROR" in r.stdout
    good = tmp_path / "bad.yaml"
    good.write_text(yaml.safe_dump(manifest()))
    r = subprocess.run(VALIDATE + ["--manifests", str(tmp_path), "--json"], capture_output=True, text=True)
    assert r.returncode == 0 and json.loads(r.stdout)["valid"] is True


def test_references_cli(tmp_path):
    (tmp_path / "deploy-x.json").write_text(json.dumps({"apps": {"a": {"url": "https://a"}}, "n": 3, "flag": True, "none": None}))
    out = tmp_path / "refs.json"
    r = subprocess.run(RENDER + ["references", "--contracts-dir", str(tmp_path), "--out", str(out)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    refs = json.loads(out.read_text())["contract_references"]
    assert refs == {"deploy-x.apps.a.url": "https://a", "deploy-x.n": "3", "deploy-x.flag": "true"}


def test_lab_manifests_cover_every_enterprise_hello_service():
    services = {yaml.safe_load(p.read_text())["metadata"]["service"] for p in (PKG / "onboarding/dev").glob("*.yaml")}
    expected = {"hello-frontend", "hello-bff", "hello-orders-api", "hello-catalog-api", "hello-inventory-api", "hello-durable",
                "hello-worker", "hello-partner-sim", "hello-jobs", "hello-functions", "telemetry-pipeline"}
    families = {"sql", "sqlmi", "sqlvm", "postgresql", "postgresql-elastic", "horizondb", "mysql", "cosmos-nosql", "cosmos-mongo",
                "documentdb", "cosmos-cassandra", "cassandra-mi", "cosmos-gremlin", "cosmos-table", "table-storage", "redis",
                "ledger", "blob", "adls", "search", "adx"}
    expected |= {f"hello-dbadapter-{f}" for f in families}
    assert expected <= services


def test_rendered_documents_match_rendered_schema():
    for name, doc in all_rendered():
        assert not lib.schema_errors(doc, "rendered-service.v1.schema.json"), name
