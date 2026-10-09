"""Tests against the real catalog/components.yaml and environments/ (stub files at each path)."""

from __future__ import annotations

from pathlib import Path

import pytest
from fixture_repo import REPO_ROOT, commit_all, make_real_registry_repo, record_successful_deployment, write

from tools.changeset.graph import Graph
from tools.changeset.registry import load_registry
from tools.changeset.select import select_deploy, select_pr
from tools.changeset.store import LocalStore
from tools.changeset.trees import WorkTree
from tools.config.lib import ConfigError, load_environment, load_profile, resolve_enabled


@pytest.fixture(scope="module")
def real():
    tree = WorkTree(REPO_ROOT)
    reg = load_registry(tree)
    return tree, reg, Graph(reg)


def test_real_registry_is_valid_and_acyclic(real):
    _tree, reg, graph = real
    assert graph.find_cycle() is None
    assert len(graph.layers()) >= 5
    assert reg.get("bootstrap").pipeline == "manual"


@pytest.mark.parametrize("profile", ["minimal", "enterprise", "full", "observability-only", "specialized", "custom"])
def test_real_profiles_resolve_or_explain(real, profile):
    tree, reg, graph = real
    env = load_environment(tree, "dev")
    prof = load_profile(tree, profile)
    if profile == "custom":
        env = dict(env, profile="custom", custom_components=["deploy-core-aca"])
    try:
        enabled, _notes = resolve_enabled(reg, graph, env, prof)
    except ConfigError as exc:
        # a non-custom profile that is not closed under hard dependencies must say exactly what is missing
        assert profile != "custom"
        assert "requires" in str(exc) and "not enabled in profile" in str(exc)
        return
    for cid in enabled:
        for up in graph.hard_upstream(cid):
            assert up in enabled or reg.get(up).pipeline == "manual"
    if profile == "custom":
        assert {"deploy-core-aca", "platform-containerapps", "foundation-network", "svc-bff"} <= enabled


@pytest.mark.parametrize("profile", ["minimal", "enterprise", "full", "observability-only"])
def test_core_profiles_resolve(real, profile):
    tree, reg, graph = real
    resolve_enabled(reg, graph, load_environment(tree, "dev"), load_profile(tree, profile))


def test_real_registry_api_change(tmp_path):
    repo = make_real_registry_repo(tmp_path)
    store = LocalStore(tmp_path / "records")
    record_successful_deployment(repo, tmp_path / "records")
    write(repo, "applications/services/orders-api/src/main.txt", "orders v2\n")
    commit_all(repo, "orders change")
    doc = select_deploy(repo, "dev", store)
    assert doc["profile"] == "minimal"
    assert doc["artifacts_to_build"] == ["svc-orders-api"]
    assert doc["summary"]["plan"] == ["deploy-core-aca"]     # deploy-core-aks is not in the minimal profile


def test_real_registry_pr_validation_reaches_both_core_roots(tmp_path):
    repo = make_real_registry_repo(tmp_path)
    from fixture_repo import git

    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "applications/shared/dotnet/Hello.Common/Common.cs", "// shared v2\n")
    commit_all(repo, "shared dotnet")
    doc = select_pr(repo, "dev", target="main")
    assert set(doc["artifacts_to_build"]) == {"svc-bff", "svc-orders-api", "svc-inventory-api", "svc-durable"}
    assert {"deploy-core-aks", "deploy-core-aca"} <= set(doc["summary"]["validate"])
    assert set(doc["summary"]["plan"]) <= set(doc["enabled"])


def test_real_registry_monitoring_change(tmp_path):
    repo = make_real_registry_repo(tmp_path)
    store = LocalStore(tmp_path / "records")
    record_successful_deployment(repo, tmp_path / "records")
    write(repo, "observability/archetypes/web.yaml", "x: 1\n")
    commit_all(repo, "archetype")
    doc = select_deploy(repo, "dev", store)
    assert doc["summary"]["plan"] == ["obs-monitoring"] and doc["artifacts_to_build"] == []


def test_real_repo_records_bootstrap_never_selected(tmp_path):
    repo = make_real_registry_repo(tmp_path)
    doc = select_deploy(repo, "dev", None)
    assert "bootstrap" not in doc["components"]
    assert Path(repo / "bootstrap").exists()
