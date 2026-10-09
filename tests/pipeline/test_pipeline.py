"""Generated stages, stage-condition semantics, simulation and pipeline lint."""

from __future__ import annotations

import copy
import itertools
from pathlib import Path

import pytest
import yaml
from fixture_repo import REPO_ROOT

from tools.changeset.graph import Graph
from tools.changeset.registry import load_registry, var_id
from tools.changeset.trees import WorkTree
from tools.pipeline.conditions import EvalContext, ExpressionError, evaluate, parse
from tools.pipeline.generate import build, component_condition, main as generate_main, stage_map
from tools.pipeline.simulate import simulate
from tools.validate.pipeline_lint import lint

GEN = REPO_ROOT / "pipelines/generated/component-stages.yml"
OK_GATES = {"Select": "Succeeded", "Validate": "Succeeded", "Security": "Succeeded"}


@pytest.fixture(scope="module")
def reg():
    return load_registry(WorkTree(REPO_ROOT))


@pytest.fixture(scope="module")
def generated():
    return yaml.safe_load(GEN.read_text())


def test_generated_yaml_parses_and_has_one_stage_per_component(reg, generated):
    stages = stage_map(generated)
    comp_stages = [s for s in stages if s.startswith("C_")]
    expected = {c.stage_name for c in reg if c.kind == "terraform" and c.pipeline != "manual"}
    assert set(comp_stages) == expected and len(comp_stages) == len(expected)
    assert "C_bootstrap" not in stages and "C_docs" not in stages
    names = [s.get("stage") for s in generated["stages"] if "stage" in s]
    assert len(names) == len(set(names))
    build_jobs = [j["parameters"]["component"] for j in stages["Build"]["jobs"]]
    assert sorted(build_jobs) == sorted(c.id for c in reg if c.is_artifact)
    for c in reg:
        if c.deployable:
            st = stages[c.stage_name]
            assert st["lockBehavior"] == "sequential"
            assert {"Select", "Validate", "Security"} <= set(st["dependsOn"])
            assert ("Build" in st["dependsOn"]) == bool(c.artifacts)
            parse(st["condition"])


def test_generated_file_is_up_to_date():
    assert generate_main(["--repo", str(REPO_ROOT), "--check"]) == 0


def test_stage_dependencies_are_transitive_upstream(reg, generated):
    g = Graph(reg)
    stages = stage_map(generated)
    st = stages["C_deploy_core_aca"]
    for up in g.transitive_upstream("deploy-core-aca"):
        if reg.get(up).deployable:
            assert f"C_{var_id(up)}" in st["dependsOn"]


def _ctx(upstream_results: dict, selected: dict, me: str, build_ready=(), run_canceled=False, gates=None):
    deps = {k: {"result": v, "outputs": {}} for k, v in (gates or OK_GATES).items()}
    sel_out = {f"select.detect.sel_{var_id(c)}": ("true" if s else "false") for c, s in selected.items()}
    sel_out[f"select.detect.sel_{var_id(me)}"] = "true"
    deps["Select"]["outputs"] = sel_out
    deps["Build"] = {"result": "Succeeded", "outputs": {f"B_{var_id(a)}.ready.ready": "true" for a in build_ready}}
    for c, r in upstream_results.items():
        deps[f"C_{var_id(c)}"] = {"result": r, "outputs": {}}
    return EvalContext(dependencies=deps, run_canceled=run_canceled)


def test_condition_skipped_unselected_upstream_does_not_block(reg):
    g = Graph(reg)
    me = reg.get("platform-containerapps")
    ups = [reg.get(u) for u in sorted(g.transitive_upstream(me.id)) if reg.get(u).deployable]
    cond = component_condition(me, ups)
    names = [u.id for u in ups]
    # every combination of Succeeded / SucceededWithIssues / Skipped(not selected) runs
    for combo in itertools.product(["Succeeded", "SucceededWithIssues", "Skipped"], repeat=len(names)):
        results = dict(zip(names, combo))
        selected = {n: r != "Skipped" for n, r in results.items()}
        assert evaluate(cond, _ctx(results, selected, me.id)), results


@pytest.mark.parametrize("bad", ["Failed", "Canceled"])
def test_condition_failed_or_canceled_upstream_blocks(reg, bad):
    me = reg.get("platform-shared")
    ups = [reg.get("foundation-network"), reg.get("foundation-identity")]
    cond = component_condition(me, ups)
    ctx = _ctx({"foundation-network": bad, "foundation-identity": "Succeeded"},
               {"foundation-network": True, "foundation-identity": True}, me.id)
    assert not evaluate(cond, ctx)


def test_condition_selected_but_skipped_upstream_blocks(reg):
    """foundation-network failed -> identity (selected) skipped -> shared must not run."""
    me = reg.get("platform-shared")
    cond = component_condition(me, [reg.get("foundation-network"), reg.get("foundation-identity")])
    ctx = _ctx({"foundation-network": "Skipped", "foundation-identity": "Skipped"},
               {"foundation-network": False, "foundation-identity": True}, me.id)
    assert not evaluate(cond, ctx)


def test_condition_not_selected_run_canceled_and_gates(reg):
    me = reg.get("foundation-network")
    cond = component_condition(me, [])
    assert evaluate(cond, _ctx({}, {}, me.id))
    ctx = _ctx({}, {}, me.id)
    ctx.dependencies["Select"]["outputs"][f"select.detect.sel_{me.var_id}"] = "false"
    assert not evaluate(cond, ctx)
    assert not evaluate(cond, _ctx({}, {}, me.id, run_canceled=True))
    assert not evaluate(cond, _ctx({}, {}, me.id, gates={**OK_GATES, "Validate": "Failed"}))
    assert not evaluate(cond, _ctx({}, {}, me.id, gates={**OK_GATES, "Security": "Failed"}))


def test_condition_requires_own_artifacts_only(reg):
    me = reg.get("deploy-frontend")
    cond = component_condition(me, [])
    assert not evaluate(cond, _ctx({}, {}, me.id, build_ready=["svc-bff"]))
    assert evaluate(cond, _ctx({}, {}, me.id, build_ready=["svc-frontend"]))


def test_simulated_run_failed_upstream_blocks_transitively(generated):
    sel = {"sel_foundation_network": "true", "apply_foundation_network": "true",
           "sel_foundation_identity": "false", "sel_platform_shared": "true", "apply_platform_shared": "true",
           "any_build": "false", "any_deploy": "true", "mode": "deploy", "has_retirements": "false"}
    res = simulate(generated, sel, {"foundation-network": 1, "platform-shared": 2})
    assert res["results"]["C_foundation_network"] == "Failed"
    assert res["results"]["C_foundation_identity"] == "Skipped"
    assert res["results"]["C_platform_shared"] == "Skipped"   # transitive dependsOn catches it
    assert res["applied"] == []
    assert res["results"]["Retire"] == "Skipped"
    res = simulate(generated, sel, {"foundation-network": 2, "platform-shared": 0})
    assert res["applied"] == ["foundation-network"]
    assert res["results"]["C_platform_shared"] == "Succeeded"
    assert res["results"]["Verify"] == "Succeeded"


def test_conditions_never_use_always(generated):
    text = GEN.read_text()
    assert "always()" not in text
    assert "succeededOrFailed()" not in text


def test_lint_passes_on_repository():
    assert lint(REPO_ROOT) == []


def test_lint_detects_violations(tmp_path):
    import shutil

    for rel in ("azure-pipelines.yml", "pipelines", "tools", "catalog", "versions.yaml", "environments"):
        src = REPO_ROOT / rel
        (shutil.copytree if src.is_dir() else shutil.copy)(src, tmp_path / rel)
    gen = tmp_path / "pipelines/generated/component-stages.yml"
    doc = yaml.safe_load(gen.read_text())
    st = next(s for s in doc["stages"] if s.get("stage") == "C_platform_shared")
    st["condition"] = "always()"
    st.pop("lockBehavior")
    gen.write_text(yaml.safe_dump(doc, sort_keys=False))
    root = yaml.safe_load((tmp_path / "azure-pipelines.yml").read_text())
    root["lockBehavior"] = "runLatest"
    (tmp_path / "azure-pipelines.yml").write_text(yaml.safe_dump(root, sort_keys=False))
    errors = "\n".join(lint(tmp_path))
    for rule in ("PL001", "PL002", "PL004", "PL006"):
        assert rule in errors, rule


def test_concurrency_protection_is_configured_and_documented():
    root = yaml.safe_load((REPO_ROOT / "azure-pipelines.yml").read_text())
    assert root["lockBehavior"] == "sequential"
    assert all(s.get("always") is True for s in root["schedules"])
    readme = (REPO_ROOT / "pipelines/README.md").read_text()
    assert "Exclusive lock" in readme and "lockBehavior" in readme


def test_pr_builds_compile_without_credentials():
    root = (REPO_ROOT / "azure-pipelines.yml").read_text()
    doc = yaml.safe_load(root)
    stages = doc["stages"]
    # the generated (credentialed) stages are only inserted when Build.Reason != PullRequest
    key = next(k for s in stages if isinstance(s, dict) for k in s if str(k).startswith("${{ if ne(variables['Build.Reason'], 'PullRequest')"))
    assert key
    validate = (REPO_ROOT / "pipelines/templates/validate.yml").read_text()
    security = (REPO_ROOT / "pipelines/templates/security-scan.yml").read_text()
    for t in (validate, security):
        assert "azureSubscription" not in t and "group:" not in t


def test_expression_parser_rejects_garbage():
    with pytest.raises(ExpressionError):
        parse("and(eq(1, 2)")
    assert evaluate("in('SucceededWithIssues', 'Succeeded', 'succeededwithissues')", EvalContext())
    assert evaluate("eq(dependencies.X.outputs['a.b.c'], '')", EvalContext())
