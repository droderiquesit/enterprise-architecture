"""Profile `features` -> component settings mapping (tools/config/features.py, environments/profiles/README.md)."""

from __future__ import annotations

import re

import pytest
import yaml
from fixture_repo import REPO_ROOT

from tools.changeset.registry import load_registry
from tools.changeset.trees import WorkTree
from tools.config.features import DOCUMENTED_ONLY, FEATURE_MAP, FeatureError, feature_settings, mapping_rows, validate_features
from tools.config.lib import ConfigError, load_environment, load_profile, render_component

PROFILES = ["minimal", "enterprise", "full", "specialized", "observability-only", "custom"]


@pytest.fixture(scope="module")
def tree():
    return WorkTree(REPO_ROOT)


@pytest.fixture(scope="module")
def registry(tree):
    return load_registry(tree)


def _settings_text(registry, component_id: str) -> str:
    root = REPO_ROOT / registry.get(component_id).path
    text = ""
    for tf in sorted(root.glob("*.tf")):
        body = tf.read_text()
        m = re.search(r'variable\s+"settings"\s*\{', body)
        if m:
            text += body[m.start():]
    assert text, f"{component_id}: no variable \"settings\""
    return text


@pytest.mark.parametrize("profile", PROFILES)
def test_every_profile_feature_is_mapped_or_documented(tree, profile):
    doc = load_profile(tree, profile)            # load_profile rejects unknown features
    for key in doc.get("features") or {}:
        assert key in FEATURE_MAP or key in DOCUMENTED_ONLY


def test_every_target_exists_in_the_root_settings_type(registry):
    for feature, comp, path in mapping_rows():
        text = _settings_text(registry, comp)
        leaf = path.split(".")[-1]
        assert re.search(rf"\b{re.escape(leaf)}\s*=\s*optional\(", text), f"{feature}: {comp} settings has no {path}"
        for parent in path.split(".")[:-1]:
            if parent == "hello-frontend":           # map key, not an attribute
                continue
            assert re.search(rf"\b{re.escape(parent)}\s*=\s*optional\(", text), f"{feature}: {comp} settings has no {parent}"


def test_trace_sample_rate_reaches_every_deploy_root_that_declares_it(registry):
    declaring = {
        c.id for c in registry
        if c.id.startswith("deploy-") and c.is_terraform
        and re.search(r"\btrace_sample_ratio\s*=\s*optional\(", _settings_text(registry, c.id))
    }
    mapped = {comp for comp, _, _ in FEATURE_MAP["trace_sample_rate"]}
    assert declaring == mapped


def test_mapping_values():
    f = {"topology": "hub-spoke", "egress": "nat-gateway", "firewall": True, "bastion": True, "app_gateway": False,
         "front_door": False, "apim": False, "service_bus_sku": "Premium", "rum_session_sample_rate": 50,
         "session_replay": False, "trace_sample_rate": 0.5, "private_endpoints": True}
    assert feature_settings(f, "foundation-network") == {"topology": "hub-spoke", "egress": "nat-gateway",
                                                          "firewall_subnet": True, "appgw_subnet": False}
    assert feature_settings(f, "foundation-edge") == {"firewall": {"enabled": True}, "bastion": {"enabled": True},
                                                       "app_gateway": {"enabled": False}, "front_door": {"enabled": False},
                                                       "apim": {"enabled": False}}
    assert feature_settings(f, "platform-messaging") == {"sku": "Premium"}
    assert feature_settings(f, "obs-prereqs") == {"rum_applications": {"hello-frontend": {
        "session_sample_rate": 50, "session_replay_sample_rate": 0}}}
    assert feature_settings({"session_replay": True}, "obs-prereqs") == {
        "rum_applications": {"hello-frontend": {"session_replay_sample_rate": 100}}}
    assert feature_settings(f, "deploy-durable") == {"trace_sample_ratio": 0.5}
    assert feature_settings(f, "deploy-frontend") == {}
    assert feature_settings(f, "platform-sql") == {}


@pytest.mark.parametrize("bad", [{"nope": 1}, {"trace_sample_rate": 2}, {"service_bus_sku": "Basic"},
                                 {"firewall": "yes"}, {"rum_session_sample_rate": 101}, {"topology": "mesh"}])
def test_invalid_features_rejected(bad):
    with pytest.raises(FeatureError):
        validate_features(bad)


def test_precedence_feature_lt_profile_lt_environment(tree, registry):
    env = load_environment(tree, "dev")
    profile = {"profile": "custom", "components": [],
               "features": {"trace_sample_rate": 0.25, "service_bus_sku": "Premium", "rum_session_sample_rate": 20},
               "component_settings": {"platform-messaging": {"sku": "Standard"},
                                      "obs-prereqs": {"rum_applications": {"hello-frontend": {"track_user_interactions": False}}}}}
    env = dict(env, components={"deploy-jobs": {"trace_sample_ratio": 0.75}})
    assert render_component(tree, registry, env, profile, "deploy-durable")["settings"] == {"trace_sample_ratio": 0.25}
    assert render_component(tree, registry, env, profile, "deploy-jobs")["settings"]["trace_sample_ratio"] == 0.75
    assert render_component(tree, registry, env, profile, "platform-messaging")["settings"]["sku"] == "Standard"
    rum = render_component(tree, registry, env, profile, "obs-prereqs")["settings"]["rum_applications"]["hello-frontend"]
    assert rum == {"session_sample_rate": 20, "track_user_interactions": False}   # maps deep-merge


def test_unknown_feature_fails_render(tree, registry):
    env = load_environment(tree, "dev")
    with pytest.raises(ConfigError, match="unknown profile feature 'teleport'"):
        render_component(tree, registry, env, {"profile": "custom", "components": [], "features": {"teleport": True}},
                         "foundation-network")


def test_readme_table_lists_every_mapping():
    text = (REPO_ROOT / "environments/profiles/README.md").read_text()
    for feature, comp, path in mapping_rows():
        assert f"`{feature}`" in text and comp in text and f"`{path}" in text, (feature, comp, path)
    for key in DOCUMENTED_ONLY:
        assert f"`{key}`" in text


def test_minimal_profile_creates_only_consumed_subscriptions(tree, registry):
    env = dict(load_environment(tree, "dev"), profile="minimal")
    prof = load_profile(tree, "minimal")
    subs = render_component(tree, registry, env, prof, "platform-messaging")["settings"]["subscriptions"]
    assert set(subs) == {"fulfillment"} and subs["fulfillment"]["consumer"] == "hello-durable"
    assert "deploy-durable" in prof["components"]
    for consumer in ("deploy-vm-workloads", "deploy-functions", "deploy-logicapps", "deploy-core-aks"):
        assert consumer not in prof["components"]
    assert yaml.safe_load((REPO_ROOT / "environments/profiles/minimal.yaml").read_text())["features"]["service_bus_sku"] == "Standard"
