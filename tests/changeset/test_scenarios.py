"""Required change-detection scenarios (synthetic registry in a temporary git repository)."""

from __future__ import annotations

import json

import pytest
import yaml
from fixture_repo import (
    SYNTHETIC_REGISTRY,
    commit_all,
    git,
    make_synthetic_repo,
    record_successful_deployment,
    write,
)

from tools.changeset.ado import output_variables
from tools.changeset.graph import CycleError, Graph
from tools.changeset.planresults import apply_set
from tools.changeset.registry import load_registry
from tools.changeset.select import select_deploy, select_pr
from tools.changeset.store import LocalStore
from tools.changeset.trees import WorkTree
from tools.pipeline.generate import build as build_stages
from tools.pipeline.simulate import simulate


@pytest.fixture()
def deployed(tmp_path):
    """Synthetic repo with a recorded, fully successful previous deployment."""
    repo = make_synthetic_repo(tmp_path)
    records = tmp_path / "records"
    record_successful_deployment(repo, records)
    return repo, LocalStore(records)


def _simulate(repo, doc, plan_exit, **kw):
    """Platform pipeline, then applications pipeline (as the resource trigger orders them)."""
    reg = load_registry(WorkTree(repo))
    outs = output_variables(doc, reg)
    merged = {"results": {}, "applied": [], "planned": []}
    for scope in ("platform", "applications"):
        sim = simulate(build_stages(reg, scope), outs, plan_exit, **kw)
        merged["results"].update({k: v for k, v in sim["results"].items() if k.startswith(("P_", "C_", "Build"))})
        merged["applied"] += sim["applied"]
        merged["planned"] += sim["planned"]
    merged["applied"].sort()
    merged["planned"].sort()
    return merged


# --------------------------------------------------------------------------- 1
def test_api_change_builds_service_and_selects_only_consuming_deploy_roots(deployed):
    repo, store = deployed
    write(repo, "applications/services/orders-api/src/Program.cs", "// orders v2\n")
    commit_all(repo, "orders-api change")
    doc = select_deploy(repo, "dev", store)
    assert doc["artifacts_to_build"] == ["svc-orders-api"]
    # the other artifact of the selected root is resolved (existing digest), not rebuilt
    assert doc["artifacts_to_resolve"] == ["svc-bff"]
    # deploy-core-aks also consumes svc-orders-api but is not enabled in this environment
    assert doc["summary"]["plan"] == ["deploy-core-aca"]
    assert doc["components"]["deploy-core-aca"]["changed_parts"] == ["artifacts"]
    # an artifact-only change does not re-plan contract consumers (frontend, monitoring)
    assert not doc["components"]["deploy-frontend"]["plan"]
    assert not doc["components"]["obs-monitoring"]["plan"]


def test_api_change_pr_mode_validates_all_consumers_plans_enabled_only(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "applications/services/orders-api/src/Program.cs", "// orders v2\n")
    commit_all(repo, "orders-api change")
    doc = select_pr(repo, "dev", target="main")
    assert doc["path_owners"] == ["svc-orders-api"]
    assert doc["artifacts_to_build"] == ["svc-orders-api"]
    assert {"deploy-core-aks", "deploy-core-aca"} <= set(doc["summary"]["validate"])
    assert doc["summary"]["plan"] == ["deploy-core-aca"]
    assert doc["summary"]["apply_candidates"] == []
    outs = output_variables(doc, load_registry(WorkTree(repo)))
    assert all(v == "false" for k, v in outs.items() if k.startswith(("sel_", "apply_", "build_")))


# --------------------------------------------------------------------------- 2
def test_monitoring_rule_change_selects_only_obs_monitoring(deployed):
    repo, store = deployed
    write(repo, "observability/archetypes/web-service.yaml", "monitors: [latency, errors]\n")
    commit_all(repo, "archetype change")
    doc = select_deploy(repo, "dev", store)
    assert doc["summary"]["plan"] == ["obs-monitoring"]
    assert doc["artifacts_to_build"] == [] and doc["artifacts_to_resolve"] == []
    write(repo, "observability/onboarding/services.yaml", "services: [hello-bff, hello-orders-api]\n")
    commit_all(repo, "onboarding change")
    doc = select_deploy(repo, "dev", store)
    assert doc["summary"]["plan"] == ["obs-monitoring"]
    assert doc["artifacts_to_build"] == []


# --------------------------------------------------------------------------- 3
def test_shared_module_change_plans_all_consumers_applies_only_changed_plans(deployed):
    repo, store = deployed
    write(repo, "foundation/modules/naming/main.tf", 'variable "workload" {\n  type    = string\n  default = "y"\n}\n')
    commit_all(repo, "naming module change")
    doc = select_deploy(repo, "dev", store)
    planned = set(doc["summary"]["plan"])
    users = {"foundation-network", "foundation-identity", "platform-shared", "platform-db-sql"}
    assert users <= planned
    for cid in users:
        assert doc["components"][cid]["changed_parts"] == ["source"]
    # consumers of the module users are planned too (their inputs may change)
    assert {"platform-containerapps", "obs-telemetry-transport", "deploy-core-aca"} <= planned
    # components unrelated to the module and its users are not
    assert not {"platform-db-cosmos", "deploy-dbadapters", "obs-prereqs"} & planned
    exit_codes = {cid: 0 for cid in planned}
    exit_codes["platform-db-sql"] = 2
    assert apply_set(doc, exit_codes)["apply"] == ["platform-db-sql"]
    sim = _simulate(repo, doc, exit_codes)
    assert sim["applied"] == ["platform-db-sql"]
    assert set(sim["planned"]) == planned


# --------------------------------------------------------------------------- 4
def test_foundation_change_applies_network_plans_consumers_skips_unrelated(deployed):
    repo, store = deployed
    write(repo, "foundation/network/main.tf", "# foundation-network v2\nlocals {\n  component = \"foundation-network\"\n}\n"
          "\nmodule \"naming\" {\n  source = \"../../foundation/modules/naming\"\n}\n")
    commit_all(repo, "network change")
    doc = select_deploy(repo, "dev", store)
    planned = set(doc["summary"]["plan"])
    assert "foundation-network" in planned
    assert {"foundation-identity", "platform-shared", "platform-containerapps", "platform-db-sql",
            "obs-telemetry-transport", "deploy-core-aca"} <= planned
    assert "deploy-dbadapters" not in planned and "platform-db-cosmos" not in planned
    # consumers reached through the network get apply_candidate, but apply needs a plan with changes
    exit_codes = {cid: 0 for cid in planned}
    exit_codes["foundation-network"] = 2
    sim = _simulate(repo, doc, exit_codes)
    assert sim["applied"] == ["foundation-network"]
    assert sim["results"]["P_deploy_core_aca"] == "Succeeded"       # planned, empty plan ...
    assert sim["results"]["C_deploy_core_aca"] == "Skipped"         # ... so not redeployed (no approval asked)
    assert sim["results"]["P_deploy_dbadapters"] == "Skipped"
    # a failing network apply blocks every consumer stage of the platform pipeline
    reg = load_registry(WorkTree(repo))
    plat = simulate(build_stages(reg, "platform"), output_variables(doc, reg), exit_codes, apply_fail={"foundation-network"})
    assert plat["results"]["C_foundation_network"] == "Failed"
    assert plat["results"]["P_foundation_identity"] == "Skipped"
    assert plat["results"]["P_obs_telemetry_transport"] == "Skipped"
    assert plat["applied"] == []
    # ... and the applications pipeline does not even plan its consumers: they wait for the platform
    apps = select_deploy(repo, "dev", store, scope="applications")
    assert apps["summary"]["plan"] == []
    assert "deploy-core-aca" in apps["summary"]["waiting"]
    assert "foundation-network" in apps["components"]["deploy-core-aca"]["waiting_for"]


# --------------------------------------------------------------------------- 5
def test_docs_only_change_deploys_nothing(deployed, tmp_path):
    repo, store = deployed
    write(repo, "docs/index.md", "# docs v2\n")
    write(repo, "foundation/network/README.md", "# network docs v2\n")
    write(repo, "README.md", "# lab v2\n")
    commit_all(repo, "docs")
    doc = select_deploy(repo, "dev", store)
    assert doc["summary"]["plan"] == [] and doc["artifacts_to_build"] == []
    outs = output_variables(doc, load_registry(WorkTree(repo)))
    assert outs["any_deploy"] == "false" and outs["any_build"] == "false"
    # PR view: docs (and the owning component) are validated, nothing would be planned
    git(repo, "branch", "-f", "base-for-docs", "HEAD~1")
    pr = select_pr(repo, "dev", base="base-for-docs")
    assert pr["summary"]["plan"] == []
    assert set(pr["summary"]["validate"]) == {"docs", "foundation-network"}


# --------------------------------------------------------------------------- 6
def test_failed_previous_deployment_is_reselected(deployed):
    repo, store = deployed
    rec = store.get_json("dev/platform-db-sql.json")
    rec["status"] = "failed"
    store.put_json("dev/platform-db-sql.json", rec)
    for status in ("partial", "canceled"):
        r = store.get_json("dev/obs-prereqs.json")
        r["status"] = status
        store.put_json("dev/obs-prereqs.json", r)
        doc = select_deploy(repo, "dev", store)
        assert doc["components"]["obs-prereqs"]["plan"]
        assert f"previous deployment status={status}" in doc["components"]["obs-prereqs"]["reason"]
    doc = select_deploy(repo, "dev", store)
    e = doc["components"]["platform-db-sql"]
    assert e["plan"] and e["apply_candidate"]
    assert "previous deployment status=failed" in e["reason"]
    # resumability: once the record says succeeded again, nothing is selected
    rec["status"] = "succeeded"
    store.put_json("dev/platform-db-sql.json", rec)
    r = store.get_json("dev/obs-prereqs.json")
    r["status"] = "succeeded"
    store.put_json("dev/obs-prereqs.json", r)
    assert select_deploy(repo, "dev", store)["summary"]["plan"] == []


# --------------------------------------------------------------------------- 7
def test_renamed_file_within_component_selects_component_once(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    git(repo, "checkout", "-q", "-b", "feature")
    git(repo, "mv", "foundation/network/main.tf", "foundation/network/network.tf")
    commit_all(repo, "rename")
    doc = select_pr(repo, "dev", target="main")
    renames = [c for c in doc["changed_files"] if c["status"] == "R"]
    assert renames and renames[0]["old_path"] == "foundation/network/main.tf"
    assert doc["path_owners"] == ["foundation-network"]
    assert list(doc["components"]).count("foundation-network") == 1
    assert sorted(doc["components"]["foundation-network"]["changed_paths"]) == [
        "foundation/network/main.tf", "foundation/network/network.tf"]


def test_rename_across_components_selects_both(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "applications/services/orders-api/src/Pricing.cs", "// a reasonably long file body\n" * 20)
    commit_all(repo, "add pricing")
    git(repo, "branch", "-f", "base-for-rename")
    git(repo, "mv", "applications/services/orders-api/src/Pricing.cs", "applications/services/bff/src/Pricing.cs")
    commit_all(repo, "move pricing to bff")
    doc = select_pr(repo, "dev", base="base-for-rename")
    assert any(c["status"] == "R" for c in doc["changed_files"])
    assert doc["path_owners"] == ["svc-bff", "svc-orders-api"]
    assert set(doc["artifacts_to_build"]) == {"svc-bff", "svc-orders-api"}


# --------------------------------------------------------------------------- 8
def _drop(registry: dict, *ids: str) -> dict:
    reg = json.loads(json.dumps(registry))
    reg["components"] = [c for c in reg["components"] if c["id"] not in ids]
    return reg


def test_deleted_component_is_retire_pending_and_never_destroyed_without_retirement_file(deployed):
    repo, store = deployed
    reg = _drop(SYNTHETIC_REGISTRY, "deploy-dbadapters", "platform-db-cosmos")
    write(repo, "catalog/components.yaml", yaml.safe_dump(reg, sort_keys=False))
    prof = yaml.safe_load((repo / "environments/profiles/minimal.yaml").read_text())
    prof["components"] = [c for c in prof["components"] if c not in ("deploy-dbadapters", "platform-db-cosmos")]
    write(repo, "environments/profiles/minimal.yaml", yaml.safe_dump(prof))
    git(repo, "rm", "-r", "-q", "applications/deployments/dbadapters", "platform/data/cosmos")
    commit_all(repo, "remove dbadapters + cosmos")
    doc = select_deploy(repo, "dev", store)
    ret = {r["component"]: r for r in doc["retirements"]}
    assert set(ret) == {"deploy-dbadapters", "platform-db-cosmos"}
    assert all(r["status"] == "retire-pending" for r in ret.values())
    assert doc["summary"]["retire_scheduled"] == []
    assert output_variables(doc, load_registry(WorkTree(repo)))["has_retirements"] == "false"
    assert doc["summary"]["plan"] == []          # nothing else is touched

    # wrong confirmation: still pending
    write(repo, "environments/dev/retirements.yaml", yaml.safe_dump({"retirements": [
        {"component": "platform-db-cosmos", "confirm": "platform-db-cosmo", "approved_by": "lead@example.com",
         "reason": "no longer needed"}]}))
    commit_all(repo, "bad retirement")
    doc = select_deploy(repo, "dev", store)
    assert {r["component"]: r["status"] for r in doc["retirements"]}["platform-db-cosmos"] == "retire-pending"

    # approved for both: consumers retire first
    write(repo, "environments/dev/retirements.yaml", yaml.safe_dump({"retirements": [
        {"component": "platform-db-cosmos", "confirm": "platform-db-cosmos", "approved_by": "lead@example.com",
         "reason": "no longer needed"},
        {"component": "deploy-dbadapters", "confirm": "deploy-dbadapters", "approved_by": "lead@example.com",
         "reason": "no longer needed"}]}))
    commit_all(repo, "approve retirements")
    doc = select_deploy(repo, "dev", store)
    sched = [r["component"] for r in doc["retirements"] if r["status"] == "retire-scheduled"]
    assert sched == ["deploy-dbadapters", "platform-db-cosmos"]
    assert [r["order"] for r in doc["retirements"]] == [0, 1]
    assert output_variables(doc, load_registry(WorkTree(repo)))["has_retirements"] == "true"


def test_custom_profile_keeps_hard_dependency_out_of_retirement(deployed):
    repo, store = deployed
    # platform-db-cosmos stays in the registry but its record pretends it is disabled while
    # deploy-dbadapters (enabled) still hard-depends on it -> blocked, even with approval
    prof = yaml.safe_load((repo / "environments/profiles/minimal.yaml").read_text())
    prof["components"] = [c for c in prof["components"] if c != "platform-db-cosmos"]
    prof["profile"] = "custom"
    write(repo, "environments/profiles/custom.yaml", yaml.safe_dump(prof))
    env = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    env["profile"] = "custom"
    env["custom_components"] = ["deploy-dbadapters"]
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "custom")
    doc = select_deploy(repo, "dev", store)
    # custom profile auto-adds the hard dependency, so it is never retire-pending
    assert "platform-db-cosmos" in doc["enabled"]
    assert "platform-db-cosmos" not in {r["component"] for r in doc["retirements"]}


# --------------------------------------------------------------------------- 9
def test_cyclic_graph_reports_cycle_path(tmp_path):
    reg = json.loads(json.dumps(SYNTHETIC_REGISTRY))
    for c in reg["components"]:
        if c["id"] == "foundation-network":
            c["consumes"] = ["platform-shared"]
    repo = make_synthetic_repo(tmp_path, registry=reg)
    graph = Graph(load_registry(WorkTree(repo)))
    with pytest.raises(CycleError) as exc:
        graph.check_acyclic()
    cycle = exc.value.cycle
    assert cycle[0] == cycle[-1]
    assert {"foundation-network", "platform-shared"} <= set(cycle)
    msg = str(exc.value)
    assert "dependency cycle:" in msg and " -> " in msg
    from tools.changeset.cli import main

    assert main(["--repo", str(repo), "graph"]) == 2


# -------------------------------------------------------------------------- 10
def test_pr_mode_uses_merge_base_not_head_parent(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    fork_point = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "observability/archetypes/web-service.yaml", "monitors: [latency, saturation]\n")
    commit_all(repo, "feature: monitoring")
    write(repo, "observability/archetypes/web-service.yaml", "monitors: [latency, saturation, errors]\n")
    commit_all(repo, "feature: monitoring 2")
    # the target branch advances after the fork point with an unrelated change
    git(repo, "checkout", "-q", "main")
    write(repo, "platform/data/sql/main.tf", "# sql v2\nlocals {\n  component = \"platform-db-sql\"\n}\n")
    commit_all(repo, "main: sql change")
    git(repo, "checkout", "-q", "feature")
    doc = select_pr(repo, "dev", target="main")
    assert doc["base"] == fork_point
    assert doc["path_owners"] == ["obs-monitoring"]           # both feature commits, not only HEAD~1..HEAD
    assert len(doc["changed_files"]) == 1
    assert not doc["components"]["platform-db-sql"]["validate"]  # main's change is not attributed to the PR


def test_config_change_selects_only_that_component(deployed):
    repo, store = deployed
    env = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    env["components"] = {"platform-db-sql": {"sku_name": "GP_S_Gen5_2"}}
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "sql settings")
    doc = select_deploy(repo, "dev", store)
    assert doc["components"]["platform-db-sql"]["changed_parts"] == ["config"]
    assert doc["directly_changed"] == ["platform-db-sql"]
    # a global that only foundation-network declares (network) changes only that root directly
    env["network"]["spoke_address_space"] = "10.42.0.0/16"
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "network ranges")
    doc = select_deploy(repo, "dev", store)
    assert "foundation-network" in doc["directly_changed"]
    assert "foundation-identity" not in doc["directly_changed"]


def test_retirement_refused_while_enabled_consumer_depends(deployed):
    repo, store = deployed
    # a removed component whose record says it produced a contract that enabled components still consume
    store.put_json("dev/legacy-network.json", {"component": "legacy-network", "status": "succeeded", "commit": "x",
                                                "path": "legacy/network", "produces": ["foundation-network"]})
    write(repo, "environments/dev/retirements.yaml", yaml.safe_dump({"retirements": [
        {"component": "legacy-network", "confirm": "legacy-network", "approved_by": "lead@example.com", "reason": "old"}]}))
    commit_all(repo, "approve legacy retirement")
    doc = select_deploy(repo, "dev", store)
    r = {x["component"]: x for x in doc["retirements"]}["legacy-network"]
    assert r["status"] == "retire-blocked"
    assert "foundation-identity" in r["reason"]
    assert doc["summary"]["retire_scheduled"] == []


def test_pr_validates_changed_module_without_registered_consumer(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "observability/modules/new-thing/main.tf", "# new module\n")
    commit_all(repo, "new module")
    doc = select_pr(repo, "dev", target="main")
    assert doc["modules_to_validate"] == ["observability/modules/new-thing"]
    matrix = json.loads(output_variables(doc, load_registry(WorkTree(repo)))["validate_matrix"])
    assert matrix["module_observability_modules_new_thing"]["component"] == "module:observability/modules/new-thing"
