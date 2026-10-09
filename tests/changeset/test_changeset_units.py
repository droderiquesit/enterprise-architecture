"""Unit tests: globs, module discovery, graph semantics, fingerprints, ADO output, CLI."""

from __future__ import annotations

import json

from fixture_repo import commit_all, make_synthetic_repo, write

from tools.changeset import globs
from tools.changeset.ado import logging_commands, output_variables
from tools.changeset.cli import main as cli
from tools.changeset.fingerprint import deploy_relevant, is_doc, is_test
from tools.changeset.graph import Graph, discover_modules
from tools.changeset.registry import load_registry
from tools.changeset.select import Context, auto_mode, docs_only, select_manual, select_all
from tools.changeset.trees import GitTree, WorkTree, git_blob_id


def test_glob_semantics():
    assert globs.match("observability/archetypes/**", "observability/archetypes/a/b.yaml")
    assert globs.match("**/*.md", "README.md") and globs.match("**/*.md", "a/b/c.md")
    assert not globs.match("**/*.md", "a/b/c.mdx")
    assert globs.match("applications/shared/dotnet/**", "applications/shared/dotnet/x.cs")
    assert globs.match_any(["**/*.md", "!observability/**/*.md"], "docs/a.md")
    assert not globs.match_any(["**/*.md", "!observability/**/*.md"], "observability/x/README.md")
    assert globs.match("foundation/network", "foundation/network/main.tf")
    assert not globs.match("foundation/net", "foundation/network/main.tf")


def test_doc_and_test_classification():
    assert is_doc("foundation/network/README.md") and is_doc("docs/x.png")
    assert is_test("foundation/network/tests/plan.tftest.hcl")
    assert is_test("applications/shared/dotnet/Hello.Common.Tests/A.cs")
    assert is_test("svc/test_app.py") and is_test("web/src/App.test.tsx")
    assert deploy_relevant("foundation/network/main.tf")
    assert not deploy_relevant("foundation/network/tests/x.tftest.hcl")
    assert docs_only(["docs/a.md", "README.md"]) and not docs_only(["docs/a.md", "x/main.tf"])


def test_module_discovery_is_recursive(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    write(repo, "foundation/modules/naming/main.tf", 'module "tags" {\n  source = "../tags"\n}\n')
    write(repo, "foundation/modules/tags/main.tf", "# tags\n")
    commit_all(repo, "nested modules")
    tree = WorkTree(repo)
    assert discover_modules(tree, "foundation/network") == ["foundation/modules/naming", "foundation/modules/tags"]
    assert discover_modules(tree, "obs" "ervability/lab/prereqs") == []


def test_blob_ids_match_git(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    wt, gt = WorkTree(repo), GitTree(repo, "HEAD")
    assert wt.files() == gt.files()
    assert git_blob_id(b"hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a"


def test_graph_edges_optional_after_and_implicit(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    g = Graph(load_registry(WorkTree(repo)))
    assert g.edges["deploy-core-aca"]["svc-bff"] == "artifact"
    assert g.edges["deploy-frontend"]["deploy-core-aca"] == "optional"
    # after_deployments: obs-monitoring runs after every applications-layer root
    assert g.edges["obs-monitoring"]["deploy-dbadapters"] == "after"
    # optional edges dropped when the producer is not enabled
    enabled = {"obs-prereqs", "deploy-frontend", "svc-frontend"}
    assert "deploy-core-aks" not in g.upstream("deploy-frontend", enabled)
    assert g.find_cycle() is None
    layers = g.layers()
    flat = {c: i for i, l in enumerate(layers) for c in l}
    assert flat["foundation-network"] < flat["foundation-identity"] < flat["platform-shared"] < flat["deploy-core-aca"]
    assert flat["obs-monitoring"] > flat["deploy-frontend"]


def test_fingerprint_isolation_between_components(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    before = Context(repo, "dev")
    write(repo, "platform/data/sql/tests/extra.tftest.hcl", 'run "x" {\n  command = plan\n}\n')
    commit_all(repo, "test only")
    after = Context(repo, "dev")
    # tests change the validation fingerprint, never the deploy fingerprint
    assert before.fp.deploy_fp("platform-db-sql") == after.fp.deploy_fp("platform-db-sql")
    assert before.fp.validation_fp("platform-db-sql") != after.fp.validation_fp("platform-db-sql")
    for cid in ("foundation-network", "deploy-core-aca"):
        assert before.fp.validation_fp(cid) == after.fp.validation_fp(cid)


def test_profile_component_settings_merge_into_fingerprint(tmp_path):
    import yaml

    repo = make_synthetic_repo(tmp_path)
    before = Context(repo, "dev")
    prof = yaml.safe_load((repo / "environments/profiles/minimal.yaml").read_text())
    prof["component_settings"] = {"platform-shared": {"sku": "Premium", "nested": {"a": 1, "b": 2}}}
    write(repo, "environments/profiles/minimal.yaml", yaml.safe_dump(prof))
    env = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    env["components"] = {"platform-shared": {"nested": {"b": 3}}}
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "profile settings")
    after = Context(repo, "dev")
    from tools.config.lib import render_component

    r = render_component(after.tree, after.registry, after.env_doc, after.profile_doc, "platform-shared")
    assert r["settings"] == {"sku": "Premium", "nested": {"a": 1, "b": 3}}
    assert before.fp.parts("platform-shared")["config"] != after.fp.parts("platform-shared")["config"]
    assert before.fp.parts("platform-db-sql")["config"] == after.fp.parts("platform-db-sql")["config"]


def test_ado_logging_commands(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    doc = select_all(repo, "dev", "reconcile")
    reg = load_registry(WorkTree(repo))
    outs = output_variables(doc, reg)
    assert outs["sel_foundation_network"] == "true" and outs["apply_foundation_network"] == "true"
    assert outs["sel_deploy_core_aks"] == "false"            # not enabled
    assert outs["build_svc_bff"] == "true"                   # resolve for planned deploy roots
    assert "sel_bootstrap" not in outs                       # manual component never gets a stage
    matrix = json.loads(outs["validate_matrix"])
    assert matrix["foundation_network"]["componentPath"] == "foundation/network"
    lines = logging_commands(doc, reg)
    assert "##vso[task.setvariable variable=sel_foundation_network;isOutput=true]true" in lines
    drift = select_all(repo, "dev", "drift")
    assert output_variables(drift, reg)["apply_foundation_network"] == "false"


def test_manual_mode_plans_upstream_without_apply(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    doc = select_manual(repo, "dev", ["platform-shared"])
    c = doc["components"]
    assert c["platform-shared"]["plan"] and c["platform-shared"]["apply_candidate"]
    assert c["foundation-network"]["plan"] and not c["foundation-network"]["apply_candidate"]
    assert not c["platform-containerapps"]["plan"]
    doc = select_manual(repo, "dev", ["platform-shared"], with_consumers=True)
    assert doc["components"]["platform-containerapps"]["apply_candidate"]
    assert doc["waves"][0] == ["foundation-network"]


def test_auto_mode_mapping():
    assert auto_mode("PullRequest") == "pr"
    assert auto_mode("Schedule") == "drift"
    assert auto_mode("IndividualCI") == "deploy" and auto_mode("Manual") == "deploy"


def test_cli_select_writes_document_and_ado_vars(tmp_path, capsys):
    repo = make_synthetic_repo(tmp_path)
    out = tmp_path / "sel.json"
    rc = cli(["--repo", str(repo), "select", "--mode", "deploy", "--env", "dev",
              "--records-dir", str(tmp_path / "records"), "--out", str(out), "--ado"])
    assert rc == 0
    doc = json.loads(out.read_text())
    assert doc["mode"] == "deploy" and "foundation-network" in doc["summary"]["plan"]
    printed = capsys.readouterr().out
    assert "##vso[task.setvariable variable=any_deploy;isOutput=true]true" in printed
    rc = cli(["--repo", str(repo), "select", "--mode", "manual", "--env", "dev", "--components", "nope"])
    assert rc == 1
