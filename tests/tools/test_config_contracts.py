"""tools/config and tools/contracts."""

from __future__ import annotations

import hashlib
import json

import pytest
import yaml
from fixture_repo import REPO_ROOT, commit_all, make_synthetic_repo, write

from tools.changeset.graph import Graph
from tools.changeset.registry import load_registry
from tools.changeset.store import LocalStore
from tools.changeset.trees import WorkTree
from tools.config import render as render_cli
from tools.config import resolve as resolve_cli
from tools.config.lib import ConfigError, load_environment, load_profile, resolve_enabled
from tools.contracts import publish as publish_cli
from tools.contracts import validate as validate_cli
from tools.contracts.lib import ContractError, secret_like_keys
from tools.contracts.materialize import materialize


def test_environment_schema_accepts_real_env_rejects_bad(tmp_path):
    import jsonschema

    schema = json.loads((REPO_ROOT / "environments/schema/environment.schema.json").read_text())
    doc = yaml.safe_load((REPO_ROOT / "environments/dev/environment.yaml").read_text())
    jsonschema.validate(doc, schema)
    bad = json.loads(json.dumps(doc))
    bad["environment"]["subscription_id"] = "not-a-guid"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(bad, schema)
    bad = json.loads(json.dumps(doc))
    bad["datadog"]["api_key"] = "secret"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(bad, schema)
    bad = json.loads(json.dumps(doc))
    bad["profile"] = "custom"
    with pytest.raises(jsonschema.ValidationError):      # custom needs custom_components
        jsonschema.validate(bad, schema)


def test_custom_profile_auto_adds_hard_dependencies(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    tree = WorkTree(repo)
    reg = load_registry(tree)
    env = dict(load_environment(tree, "dev"), profile="custom", custom_components=["deploy-core-aca"])
    enabled, notes = resolve_enabled(reg, Graph(reg), env, {"profile": "custom", "components": []})
    assert {"deploy-core-aca", "platform-containerapps", "obs-telemetry-transport", "foundation-network",
            "svc-bff", "svc-orders-api"} <= enabled
    assert "deploy-frontend" not in enabled                     # optional consumers are never added
    assert any("added automatically (required by" in n for n in notes)


def test_non_custom_profile_missing_dependency_fails_explicitly(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    tree = WorkTree(repo)
    reg = load_registry(tree)
    prof = load_profile(tree, "minimal")
    prof["components"] = [c for c in prof["components"] if c != "foundation-identity"]
    with pytest.raises(ConfigError) as exc:
        resolve_enabled(reg, Graph(reg), load_environment(tree, "dev"), prof)
    assert "platform-shared requires foundation-identity (hard dependency) which is not enabled in profile 'minimal'" in str(exc.value)


def test_resolve_cli(tmp_path, capsys):
    repo = make_synthetic_repo(tmp_path)
    assert resolve_cli.main(["--env", "dev", "--repo", str(repo), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "deploy-core-aca" in out["enabled"] and "bootstrap" not in out["enabled"]


def test_render_writes_tfvars_and_prints_sha(tmp_path, capsys):
    repo = make_synthetic_repo(tmp_path)
    env = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    env["components"] = {"foundation-network": {"topology": "single-spoke"}}
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "settings")
    assert render_cli.main(["--env", "dev", "--component", "foundation-network", "--repo", str(repo)]) == 0
    digest = capsys.readouterr().out.strip()
    text = (repo / "foundation/network/terraform.tfvars.json").read_text().strip()
    assert hashlib.sha256(text.encode()).hexdigest() == digest
    doc = json.loads(text)
    assert doc["settings"] == {"topology": "single-spoke"}
    assert doc["environment"]["name"] == "dev" and doc["network"]["hub_address_space"] == "10.40.0.0/20"
    assert render_cli.main(["--env", "dev", "--component", "platform-shared", "--repo", str(repo), "--stdout"]) == 0
    other = json.loads(capsys.readouterr().out)
    assert other["settings"] == {} and "network" not in other      # global only where declared


def _publish(repo, store_dir, component, data, env="dev"):
    f = repo / f"{component}-out.json"
    f.write_text(json.dumps(data))
    return publish_cli.main(["--repo", str(repo), "publish", "--env", env, "--component", component,
                             "--store", str(store_dir), "--output-json", str(f), "--commit", "abc", "--run-id", "7"])


def test_publish_validate_materialize_roundtrip(tmp_path, capsys):
    repo = make_synthetic_repo(tmp_path)
    store_dir = tmp_path / "contracts"
    assert _publish(repo, store_dir, "foundation-network", {"id": "net"}) == 0
    env = LocalStore(store_dir).get_json("dev/foundation-network/v1.json")
    assert env["version"] == "1.0.0" and env["produced_by"]["commit"] == "abc" and env["data"] == {"id": "net"}
    assert "contract_changed;isOutput=true]true" in capsys.readouterr().out
    # schema violation is rejected (foundation-network v1 requires id:string)
    assert _publish(repo, store_dir, "foundation-network", {"id": 5}) == 1
    # identity has no schema in the fixture -> accepted as long as no secrets
    assert _publish(repo, store_dir, "foundation-identity", {"kv_secret_id": "https://kv/secrets/x"}) == 0
    assert _publish(repo, store_dir, "foundation-identity", {"admin_password": "hunter2"}) == 1
    values, digest, notes = materialize(repo, "dev", "platform-shared", LocalStore(store_dir))
    assert values == {"foundation_network": {"id": "net"}, "foundation_identity": {"kv_secret_id": "https://kv/secrets/x"}}
    written = (repo / "platform/shared/contracts.auto.tfvars.json").read_text().strip()
    assert hashlib.sha256(written.encode()).hexdigest() == digest
    assert publish_cli.main(["--repo", str(repo), "check", "--env", "dev", "--component", "foundation-network",
                             "--store", str(store_dir)]) == 0
    assert publish_cli.main(["--repo", str(repo), "check", "--env", "dev", "--component", "platform-shared",
                             "--store", str(store_dir)]) == 1


def test_materialize_missing_required_and_optional_handling(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    store = LocalStore(tmp_path / "contracts")
    with pytest.raises(ContractError) as exc:
        materialize(repo, "dev", "platform-shared", store)
    assert "required foundation-network v1 not published" in str(exc.value)
    # obs-monitoring: deploy-core-aks is optional and NOT enabled -> skipped; deploy-core-aca optional+enabled but
    # unpublished -> note only
    _publish(repo, tmp_path / "contracts", "obs-prereqs", {"x": 1})
    values, _d, notes = materialize(repo, "dev", "obs-monitoring", store)
    assert values == {"obs_prereqs": {"x": 1}}
    assert any("deploy-core-aks" in n and "not enabled" in n for n in notes)
    assert any("optional deploy-core-aca" in n for n in notes)


def test_materialize_rejects_incompatible_major(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    store = LocalStore(tmp_path / "contracts")
    store.put_json("dev/foundation-network/v1.json", {
        "contract": "foundation-network", "version": "2.0.0", "environment": "dev",
        "produced_by": {"component": "foundation-network", "commit": "x"}, "data": {"id": "n"}})
    with pytest.raises(ContractError) as exc:
        materialize(repo, "dev", "foundation-identity", store)
    assert "incompatible major version" in str(exc.value)


def test_secret_detection():
    assert secret_like_keys({"a": {"client_secret": "x"}, "db_password_secret_id": "https://kv"}) == ["a.client_secret"]


def test_contract_schema_check_all_on_repository():
    assert validate_cli.main(["--repo", str(REPO_ROOT), "--all"]) == 0
