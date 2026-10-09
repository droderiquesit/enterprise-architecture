"""Generated stages (two scopes), stage-condition semantics, run simulation, entry pipelines and lint."""

from __future__ import annotations

import itertools
import shutil

import pytest
import yaml
from fixture_repo import REPO_ROOT

from tools.changeset.ado import output_variables
from tools.changeset.graph import Graph
from tools.changeset.registry import load_registry, var_id
from tools.changeset.trees import WorkTree
from tools.pipeline.conditions import EvalContext, ExpressionError, evaluate, parse
from tools.pipeline.generate import (
    OUTPUTS,
    apply_condition,
    build,
    direct_upstream,
    main as generate_main,
    plan_condition,
    stage_map,
)
from tools.pipeline.simulate import simulate
from tools.validate.pipeline_lint import lint

OK_GATES = {"Select": "Succeeded", "Validate": "Succeeded", "Security": "Succeeded"}


@pytest.fixture(scope="module")
def reg():
    return load_registry(WorkTree(REPO_ROOT))


@pytest.fixture(scope="module")
def generated():
    return {scope: yaml.safe_load((REPO_ROOT / path).read_text()) for scope, path in OUTPUTS.items()}


# ----------------------------------------------------------------- structure
def test_every_component_has_exactly_one_plan_and_apply_stage_in_its_scope(reg, generated):
    for scope, doc in generated.items():
        stages = stage_map(doc)
        plans = {s for s in stages if s.startswith("P_")}
        applies = {s for s in stages if s.startswith("C_")}
        expected = {c.var_id for c in reg if c.deployable and c.scope == scope}
        assert plans == {"P_" + v for v in expected} and applies == {"C_" + v for v in expected}
        names = [s.get("stage") for s in doc["stages"] if "stage" in s]
        assert len(names) == len(set(names))
        for c in reg:
            if c.deployable and c.scope == scope:
                p, a = stages[f"P_{c.var_id}"], stages[f"C_{c.var_id}"]
                assert p["lockBehavior"] == a["lockBehavior"] == "sequential"
                assert {"Select", "Validate", "Security"} <= set(p["dependsOn"])
                assert ("Build" in p["dependsOn"]) == bool(c.artifacts)
                assert f"P_{c.var_id}" in a["dependsOn"]
                parse(p["condition"])
                parse(a["condition"])
    all_stages = set(stage_map(generated["platform"])) & set(stage_map(generated["applications"]))
    assert not {s for s in all_stages if s.startswith(("P_", "C_"))}, "a component appears in both pipelines"
    assert "P_bootstrap" not in stage_map(generated["platform"])


def test_scopes_match_the_brief(reg):
    plat = {c.id for c in reg if c.deployable and c.scope == "platform"}
    apps = {c.id for c in reg if (c.deployable or c.is_artifact) and c.scope == "applications"}
    assert {"foundation-network", "platform-aks", "obs-prereqs", "obs-azure-integration", "obs-telemetry-transport",
            "obs-kubernetes", "obs-dbm"} <= plat
    assert {"obs-diagnostics", "obs-monitoring", "deploy-core-aks", "svc-bff"} <= apps
    assert all(c.startswith(("deploy-", "svc-", "obs-")) for c in apps)
    # obs-hosts is ordered after deploy-vm-workloads, so it must live in the applications pipeline
    assert "obs-hosts" in apps


def test_build_stage_per_scope(generated, reg):
    """Each pipeline builds exactly the artifacts of its own scope; only applications publishes Helm charts."""
    for scope in ("platform", "applications"):
        jobs = stage_map(generated[scope])["Build"]["jobs"]
        comps = [j["parameters"]["component"] for j in jobs if "component" in j["parameters"]]
        assert sorted(comps) == sorted(c.id for c in reg if c.is_artifact and c.scope == scope)
    assert [j["parameters"]["component"] for j in stage_map(generated["platform"])["Build"]["jobs"]] == ["img-dsv-fetch"]
    assert any(j["template"].endswith("helm-charts.yml") for j in stage_map(generated["applications"])["Build"]["jobs"])
    assert not any(j["template"].endswith("helm-charts.yml") for j in stage_map(generated["platform"])["Build"]["jobs"])
    assert "Verify" in stage_map(generated["applications"]) and "Verify" not in stage_map(generated["platform"])


def test_cross_scope_artifact_uses_recorded_digest(generated, reg):
    """deploy-core-aca (applications) consumes img-dsv-fetch (platform): no Build job/readiness term in the
    applications pipeline; the plan/apply jobs read it from its deployment record (recordedArtifacts)."""
    apps = stage_map(generated["applications"])
    p = apps["P_deploy_core_aca"]
    assert "B_img_dsv_fetch" not in p["condition"]
    params = p["jobs"][0]["parameters"]
    assert "img-dsv-fetch" not in params["artifacts"] and params["recordedArtifacts"] == ["img-dsv-fetch"]
    assert apps["C_deploy_core_aca"]["jobs"][0]["parameters"]["recordedArtifacts"] == ["img-dsv-fetch"]
    plat = stage_map(generated["platform"])
    t = plat["P_obs_telemetry_transport"]
    assert "Build" in t["dependsOn"] and "B_img_dsv_fetch.ready.ready" in t["condition"]
    assert "recordedArtifacts" not in t["jobs"][0]["parameters"]


def test_secret_env_components_fetch_from_dsv(generated, reg):
    plat = stage_map(generated["platform"])
    for c in reg:
        if c.deployable and c.scope == "platform":
            assert plat[f"P_{c.var_id}"]["jobs"][0]["parameters"]["secretEnv"] is bool(c.secret_env)
    assert plat["P_obs_prereqs"]["jobs"][0]["parameters"]["secretEnv"] is True
    assert plat["P_platform_db_sqlvm"]["jobs"][0]["parameters"]["secretEnv"] is True
    assert plat["P_foundation_network"]["jobs"][0]["parameters"]["secretEnv"] is False


def test_generated_files_are_up_to_date():
    assert generate_main(["--repo", str(REPO_ROOT), "--check"]) == 0


def test_plan_stage_depends_on_direct_in_scope_upstream_plan_and_apply(reg, generated):
    g = Graph(reg)
    stages = stage_map(generated["applications"])
    c = reg.get("deploy-core-aca")
    for u in direct_upstream(g, reg, c):
        if u.scope == "applications":
            assert {f"P_{u.var_id}", f"C_{u.var_id}"} <= set(stages["P_deploy_core_aca"]["dependsOn"])
        else:
            assert f"P_{u.var_id}" not in stages["P_deploy_core_aca"]["dependsOn"]


# ---------------------------------------------------------------- conditions
def _ctx(upstream: dict, selected: dict, me: str, build_ready=(), run_canceled=False, gates=None):
    """upstream: {component: (plan_result, apply_result)}"""
    deps = {k: {"result": v, "outputs": {}} for k, v in (gates or OK_GATES).items()}
    sel_out = {f"select.detect.sel_{var_id(c)}": ("true" if s else "false") for c, s in selected.items()}
    sel_out[f"select.detect.sel_{var_id(me)}"] = "true"
    deps["Select"]["outputs"] = sel_out
    deps["Build"] = {"result": "Succeeded", "outputs": {f"B_{var_id(a)}.ready.ready": "true" for a in build_ready}}
    for c, (p, a) in upstream.items():
        deps[f"P_{var_id(c)}"] = {"result": p, "outputs": {}}
        deps[f"C_{var_id(c)}"] = {"result": a, "outputs": {}}
    return EvalContext(dependencies=deps, run_canceled=run_canceled)


def test_unselected_or_unchanged_upstream_does_not_block(reg):
    me = reg.get("platform-shared")
    ups = [reg.get("foundation-network"), reg.get("foundation-identity")]
    cond = plan_condition(me, ups)
    outcomes = [("Skipped", "Skipped", False),                 # not selected
                ("Succeeded", "Skipped", True),                # selected, plan without changes
                ("Succeeded", "Succeeded", True),              # applied
                ("SucceededWithIssues", "SucceededWithIssues", True)]
    for combo in itertools.product(outcomes, repeat=2):
        upstream = {u.id: (o[0], o[1]) for u, o in zip(ups, combo)}
        selected = {u.id: o[2] for u, o in zip(ups, combo)}
        assert evaluate(cond, _ctx(upstream, selected, me.id)), combo


@pytest.mark.parametrize("plan_result,apply_result,selected", [
    ("Failed", "Skipped", True),          # plan failed
    ("Canceled", "Skipped", True),        # plan canceled
    ("Skipped", "Skipped", True),         # selected but skipped (its own upstream failed)
    ("Succeeded", "Failed", True),        # apply failed or approval rejected
    ("Succeeded", "Canceled", True),      # apply canceled
])
def test_failed_canceled_rejected_or_blocked_upstream_blocks(reg, plan_result, apply_result, selected):
    me = reg.get("platform-shared")
    cond = plan_condition(me, [reg.get("foundation-network")])
    ctx = _ctx({"foundation-network": (plan_result, apply_result)}, {"foundation-network": selected}, me.id)
    assert not evaluate(cond, ctx)


def test_gates_selection_cancel_and_artifacts(reg):
    me = reg.get("foundation-network")
    cond = plan_condition(me, [])
    assert evaluate(cond, _ctx({}, {}, me.id))
    ctx = _ctx({}, {}, me.id)
    ctx.dependencies["Select"]["outputs"][f"select.detect.sel_{me.var_id}"] = "false"
    assert not evaluate(cond, ctx)
    assert not evaluate(cond, _ctx({}, {}, me.id, run_canceled=True))
    assert not evaluate(cond, _ctx({}, {}, me.id, gates={**OK_GATES, "Validate": "Failed"}))
    assert not evaluate(cond, _ctx({}, {}, me.id, gates={**OK_GATES, "Security": "Canceled"}))
    fe = reg.get("deploy-frontend")
    assert not evaluate(plan_condition(fe, []), _ctx({}, {}, fe.id, build_ready=["svc-bff"]))
    assert evaluate(plan_condition(fe, []), _ctx({}, {}, fe.id, build_ready=["svc-frontend"]))


def test_apply_stage_condition(reg):
    me = reg.get("foundation-network")
    cond = apply_condition(me)

    def ctx(plan_result="Succeeded", changes="true", apply="true", dry="false", canceled=False):
        return EvalContext(dependencies={
            "Select": {"result": "Succeeded", "outputs": {f"select.detect.apply_{me.var_id}": apply}},
            f"P_{me.var_id}": {"result": plan_result, "outputs": {"Plan.plan.has_changes": changes}},
        }, variables={"DRY_RUN": dry}, run_canceled=canceled)

    assert evaluate(cond, ctx())
    assert not evaluate(cond, ctx(changes="false"))            # empty plan: no approval requested
    assert not evaluate(cond, ctx(apply="false"))              # drift / plan-only upstream
    assert not evaluate(cond, ctx(dry="true"))                 # dry run
    assert not evaluate(cond, ctx(plan_result="Failed"))
    assert not evaluate(cond, ctx(canceled=True))


# ---------------------------------------------------------------- simulation
def _sel(**kw):
    base = {"any_build": "false", "any_deploy": "true", "mode": "deploy", "has_retirements": "false"}
    base.update(kw)
    return base


def test_simulated_platform_run_failed_upstream_blocks_downstream(generated):
    # foundation-identity -> foundation-secrets (consumes the identity contract); platform-shared consumes both
    # foundation-network and foundation-identity. foundation-identity itself has no upstream (contract v2: no Key Vault).
    sel = _sel(sel_foundation_network="true", apply_foundation_network="true",
               sel_foundation_identity="true", apply_foundation_identity="true",
               sel_foundation_secrets="true", apply_foundation_secrets="true",
               sel_platform_shared="true", apply_platform_shared="true")
    plan = {"foundation-network": 1, "foundation-identity": 1, "foundation-secrets": 2, "platform-shared": 2}
    res = simulate(generated["platform"], sel, plan)
    assert res["results"]["P_foundation_network"] == "Failed" and res["results"]["P_foundation_identity"] == "Failed"
    assert res["results"]["P_foundation_secrets"] == "Skipped"
    assert res["results"]["P_platform_shared"] == "Skipped"
    assert res["applied"] == []
    assert res["results"]["Retire"] == "Skipped"
    res = simulate(generated["platform"], sel, {"foundation-network": 2, "foundation-identity": 0, "foundation-secrets": 0,
                                                "platform-shared": 0})
    assert res["applied"] == ["foundation-network"]
    assert res["results"]["C_foundation_identity"] == "Skipped" and res["results"]["P_platform_shared"] == "Succeeded"
    # identity planned but skipped because ITS plan failed blocks foundation-secrets; network unaffected
    res = simulate(generated["platform"], sel, {"foundation-network": 2, "foundation-identity": 1, "foundation-secrets": 2,
                                                "platform-shared": 2})
    assert res["applied"] == ["foundation-network"] and res["results"]["P_foundation_secrets"] == "Skipped"
    # approval rejected on the network apply blocks consumers
    res = simulate(generated["platform"], sel, {"foundation-network": 2, "foundation-identity": 2, "foundation-secrets": 2,
                                                "platform-shared": 2}, apply_rejected={"foundation-network"})
    assert res["results"]["P_platform_shared"] == "Skipped" and "foundation-network" not in res["applied"]
    # dry run: plans run, nothing applies, no apply stage starts (no approvals requested)
    res = simulate(generated["platform"], sel, {"foundation-network": 2}, dry_run=True)
    assert res["results"]["P_foundation_network"] == "Succeeded" and res["results"]["C_foundation_network"] == "Skipped"
    assert res["applied"] == []


def test_simulated_applications_run_new_stages(generated):
    sel = _sel(sel_deploy_core_aca="true", apply_deploy_core_aca="true", sel_obs_monitoring="true",
               apply_obs_monitoring="true", any_build="true", build_svc_bff="true", build_svc_orders_api="true",
               build_svc_catalog_api="true")
    res = simulate(generated["applications"], sel, {"deploy-core-aca": 2, "obs-monitoring": 2})
    assert res["applied"] == ["deploy-core-aca", "obs-monitoring"]
    assert res["results"]["Verify"] == "Succeeded"
    # an artifact of the root not ready -> the root does not plan; obs-monitoring (after_deployments) waits for it
    res = simulate(generated["applications"], sel, {"deploy-core-aca": 2, "obs-monitoring": 2}, build_ready={"svc_bff"})
    assert res["results"]["P_deploy_core_aca"] == "Skipped"
    assert res["results"]["P_obs_monitoring"] == "Skipped"
    # drift mode: Verify does not run
    res = simulate(generated["applications"], _sel(mode="drift", sel_deploy_core_aca="true", build_svc_bff="true",
                                                    build_svc_orders_api="true", build_svc_catalog_api="true",
                                                    any_build="true"), {"deploy-core-aca": 2})
    assert res["results"]["Verify"] == "Skipped" and res["results"]["Drift"] == "Succeeded" and res["applied"] == []


def test_conditions_never_use_always(generated):
    for scope, path in OUTPUTS.items():
        text = (REPO_ROOT / path).read_text()
        assert "always()" not in text and "succeededOrFailed()" not in text


# --------------------------------------------------------------- entries/lint
def test_exactly_two_thin_entry_pipelines():
    for entry, scope in (("azure-pipelines.yml", "platform"), ("azure-pipelines.applications.yml", "applications")):
        doc = yaml.safe_load((REPO_ROOT / entry).read_text())
        assert doc["extends"]["template"] == "pipelines/templates/universal.yml"
        assert doc["extends"]["parameters"]["scope"] == scope
        assert "stages" not in doc and "jobs" not in doc and "variables" not in doc
        assert doc["lockBehavior"] == "sequential"
        assert all(s.get("always") is True for s in doc["schedules"])
        modes = next(p for p in doc["parameters"] if p["name"] == "mode")["values"]
        assert "promote" in modes
    assert not (REPO_ROOT / "pipelines/promote.yml").exists()
    assert not (REPO_ROOT / "pipelines/observability-release.yml").exists()
    apps = yaml.safe_load((REPO_ROOT / "azure-pipelines.applications.yml").read_text())
    trig = apps["resources"]["pipelines"][0]["trigger"]
    assert trig["branches"]["include"] == ["main"] and "env-dev" in trig["tags"]


def test_release_stage_is_tag_only_and_platform_only():
    uni = yaml.safe_load((REPO_ROOT / "pipelines/templates/universal.yml").read_text())
    keys = [k for item in uni["stages"] for k in item]
    cond = keys[0]
    assert "startsWith(variables['Build.SourceBranch'], 'refs/tags/observability-v')" in cond
    assert "eq(parameters.scope, 'platform')" in cond
    first = uni["stages"][0][cond]
    assert first[0]["template"] == "observability-release.yml"
    assert keys[1] == "${{ else }}"
    assert uni["stages"][1]["${{ else }}"][0]["template"] == "universal-stages.yml"
    plat = yaml.safe_load((REPO_ROOT / "azure-pipelines.yml").read_text())
    assert "observability-v*" in plat["trigger"]["tags"]["include"]
    apps = yaml.safe_load((REPO_ROOT / "azure-pipelines.applications.yml").read_text())
    assert "tags" not in apps["trigger"]


def test_pr_builds_compile_without_credentials():
    stages = yaml.safe_load((REPO_ROOT / "pipelines/templates/universal-stages.yml").read_text())["stages"]
    key = next(k for s in stages if isinstance(s, dict) for k in s
               if str(k).startswith("${{ if ne(variables['Build.Reason'], 'PullRequest')"))
    assert key
    for t in ("validate.yml", "security-scan.yml"):
        text = (REPO_ROOT / "pipelines/templates" / t).read_text()
        assert "azureSubscription" not in text and "group:" not in text
    charts = yaml.safe_load((REPO_ROOT / "pipelines/templates/helm-charts.yml").read_text())
    job = charts["jobs"][0]
    assert job["${{ if eq(parameters.publish, false) }}"]["pool"]["vmImage"]


def test_lint_passes_on_repository():
    assert lint(REPO_ROOT) == []


def test_lint_detects_violations(tmp_path):
    for rel in ("azure-pipelines.yml", "azure-pipelines.applications.yml", "pipelines", "tools", "catalog",
                "versions.yaml", "environments"):
        src = REPO_ROOT / rel
        (shutil.copytree if src.is_dir() else shutil.copy)(src, tmp_path / rel)
    gen = tmp_path / OUTPUTS["platform"]
    doc = yaml.safe_load(gen.read_text())
    st = next(s for s in doc["stages"] if s.get("stage") == "P_platform_shared")
    st["condition"] = "always()"
    st.pop("lockBehavior")
    ap = next(s for s in doc["stages"] if s.get("stage") == "C_platform_shared")
    ap["condition"] = "and(not(canceled()), eq(1, 1))"
    gen.write_text(yaml.safe_dump(doc, sort_keys=False))
    root = yaml.safe_load((tmp_path / "azure-pipelines.yml").read_text())
    root["lockBehavior"] = "runLatest"
    (tmp_path / "azure-pipelines.yml").write_text(yaml.safe_dump(root, sort_keys=False))
    errors = "\n".join(lint(tmp_path))
    for rule in ("PL001", "PL002", "PL003", "PL004", "PL006"):
        assert rule in errors, rule


def test_concurrency_protection_is_configured_and_documented():
    readme = (REPO_ROOT / "pipelines/README.md").read_text()
    assert "Exclusive lock" in readme and "lockBehavior" in readme and "Required template" in readme


def test_expression_parser_rejects_garbage():
    with pytest.raises(ExpressionError):
        parse("and(eq(1, 2)")
    assert evaluate("in('SucceededWithIssues', 'Succeeded', 'succeededwithissues')", EvalContext())
    assert evaluate("eq(dependencies.X.outputs['a.b.c'], '')", EvalContext())


def test_ado_outputs_follow_scope(tmp_path):
    from fixture_repo import make_synthetic_repo

    from tools.changeset.select import select_all

    repo = make_synthetic_repo(tmp_path)
    r = load_registry(WorkTree(repo))
    plat = output_variables(select_all(repo, "dev", "reconcile", scope="platform"), r)
    apps = output_variables(select_all(repo, "dev", "reconcile", scope="applications"), r)
    assert plat["sel_foundation_network"] == "true" and plat["sel_deploy_core_aca"] == "false"
    assert apps["sel_deploy_core_aca"] == "true" and apps["sel_foundation_network"] == "false"
    assert plat["any_build"] == "false" and apps["any_build"] == "true"
    assert plat["scope"] == "platform" and apps["scope"] == "applications"
