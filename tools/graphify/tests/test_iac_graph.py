"""tools/graphify/iac_graph.py: the IaC layer of the Graphify knowledge graph (docs/guides/graphify.md).

A tiny synthetic repository pins every node/relation kind and the graph.json schema; a smoke run over the real
catalog checks the layer stays complete and consistent (fast: no graphify CLI needed). When the pinned graphify CLI
is on PATH the synthetic output is also loaded by `graphify god-nodes` (skipped otherwise)."""

from __future__ import annotations

import json
import shutil
import subprocess
import textwrap
import time
from pathlib import Path

import pytest
import yaml

import iac_graph as ig

REPO = Path(__file__).resolve().parents[3]
NODE_FIELDS = {"id", "label", "file_type", "source_file", "source_location", "norm_label", "_origin"}
LINK_FIELDS = {"source", "target", "relation", "confidence", "confidence_score", "source_file", "source_location",
               "weight"}
FILE_TYPES = {"code", "document", "paper", "image", "rationale", "concept"}   # graphify validate.VALID_FILE_TYPES


def write(root: Path, rel: str, text: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")


@pytest.fixture()
def tree(tmp_path: Path) -> Path:
    write(tmp_path, ".graphifyignore", """
        graphify-out/
        **/.terraform/
        pipelines/generated/
    """)
    write(tmp_path, "catalog/components.yaml", """
        schema_version: 1
        components:
          - id: net
            layer: foundation
            kind: terraform
            path: roots/net
            produces: [net]
          - id: app
            layer: applications
            kind: terraform
            path: roots/app
            consumes: [net]
            optional_consumes: [obs]
            depends_on: [net]
            artifacts: [svc-api]
            catalog_refs: [aks]
          - id: obs
            layer: observability
            kind: terraform
            path: roots/obs
            produces: [obs]
          - id: svc-api
            layer: applications
            kind: artifact
            path: services/api
            artifact: {type: container-image, name: hello-api, also: [zip-package]}
    """)
    write(tmp_path, "catalog/contracts/net.v1.schema.json", "{}\n")
    write(tmp_path, "catalog/contracts/net.v2.schema.json", "{}\n")
    write(tmp_path, "catalog/services/compute.yaml", """
        services:
          - id: aks
            display_name: Azure Kubernetes Service
            category: compute
          - id: unused
            display_name: Not referenced
    """)
    write(tmp_path, "roots/net/main.tf", """
        terraform {
          required_providers {
            azurerm = { source = "hashicorp/azurerm", version = "5.9.0" }
          }
        }
        # module "commented_out" { source = "../../modules/ghost" }
        module "naming" {
          source = "../../modules/naming"
          tags = {
            source = "python"   # nested attribute, not the module source
          }
        }
        resource "azurerm_virtual_network" "this" {
          name = "vnet"
          description = <<-EOT
            braces { inside } a heredoc and resource "fake_type" "x" {
          EOT
        }
        resource "azurerm_subnet" "a" { name = "a" }
        resource "azurerm_subnet" "b" { name = "b /* not a comment */" }
        variable "environment" {}
        output "id" { value = azurerm_virtual_network.this.id }
    """)
    write(tmp_path, "roots/app/main.tf", """
        module "registry" {
          source  = "Azure/avm-res-x/azurerm"
          version = "1.2.3"
        }
        resource "helm_release" "api" {
          chart = "${path.module}/../../charts/hello"
        }
        data "azurerm_client_config" "current" {}
    """)
    write(tmp_path, "roots/obs/main.tf", 'module "naming" {\n  source = "../../modules/naming"\n}\n')
    write(tmp_path, "modules/naming/main.tf", 'variable "prefix" {}\noutput "name" { value = var.prefix }\n')
    write(tmp_path, "roots/net/.terraform/modules/x/main.tf", 'resource "ignored_type" "x" {}\n')
    write(tmp_path, "applications/charts/hello/Chart.yaml", "apiVersion: v2\nname: hello\nversion: 1.0.0\n")
    write(tmp_path, "azure-pipelines.yml", """
        stages:
          - template: pipelines/templates/universal.yml
    """)
    write(tmp_path, "pipelines/templates/universal.yml", """
        stages:
          - template: ../generated/stages.yml
          - template: ${{ parameters.dynamic }}
    """)
    write(tmp_path, "pipelines/generated/stages.yml", """
        jobs:
          - template: ../templates/universal.yml
            parameters: {component: net}
    """)
    write(tmp_path, "environments/profiles/small.yaml", "profile: small\ncomponents:\n- net\n- app\n- unknown\n")
    write(tmp_path, "environments/dev/environment.yaml", "environment: {name: dev}\nprofile: small\n"
                                                       "custom_components: [obs]\n")
    return tmp_path


def build(root: Path, base=None) -> dict:
    return ig.Builder(root).build(base)


def edges(g: dict, relation: str) -> set:
    return {(l["source"], l["target"]) for l in g["links"] if l["relation"] == relation}


def assert_schema(g: dict) -> None:
    assert set(g) >= {"directed", "multigraph", "graph", "nodes", "links", "hyperedges"}
    ids = [n["id"] for n in g["nodes"]]
    assert len(ids) == len(set(ids)), "duplicate node ids"
    for n in g["nodes"]:
        assert NODE_FIELDS <= set(n), n
        assert n["id"].startswith("iac_") and n["_origin"] == "iac"
        assert n["file_type"] in FILE_TYPES
        assert n["norm_label"] == n["label"].lower()
        assert n["source_file"] and not n["source_file"].startswith("/")
    idset = set(ids)
    for l in g["links"]:
        assert LINK_FIELDS <= set(l), l
        assert l["confidence"] == "EXTRACTED" and l["confidence_score"] == 1.0
        assert l["source"] in idset and l["target"] in idset, l
        assert l["source_location"] is None or l["source_location"].startswith("L")


def test_synthetic_layer(tree: Path) -> None:
    g = build(tree)
    assert_schema(g)
    C = "iac_component_"
    assert edges(g, "produces_contract") >= {(C + "net", "iac_contract_net"), (C + "obs", "iac_contract_obs")}
    assert (C + "app", "iac_contract_net") in edges(g, "consumes_contract")
    assert edges(g, "consumes") == {(C + "app", C + "net"), (C + "app", C + "obs")}
    optional = [l for l in g["links"] if l["relation"] == "consumes" and l["target"] == C + "obs"]
    assert optional[0]["context"] == "optional"
    assert edges(g, "depends_on") == {(C + "app", C + "net")}
    assert edges(g, "builds") == {(C + "svc_api", "iac_artifact_svc_api")}
    assert edges(g, "consumes_artifact") == {(C + "app", "iac_artifact_svc_api")}
    assert edges(g, "implements_service") == {(C + "app", "iac_service_aks")}
    assert "iac_service_unused" not in {n["id"] for n in g["nodes"]}
    contract = next(n for n in g["nodes"] if n["id"] == "iac_contract_net")
    assert contract["versions"] == [1, 2] and contract["source_file"] == "catalog/contracts/net.v2.schema.json"

    # terraform: module sources (local + registry), resources, data, providers, charts; comments/heredocs/nested
    assert edges(g, "uses_module") == {(C + "net", "iac_tfmodule_modules_naming"),
                                       (C + "obs", "iac_tfmodule_modules_naming"),
                                       (C + "app", "iac_tfmodule_ext_azure_avm_res_x_azurerm")}
    res = [l for l in g["links"] if l["relation"] == "declares_resource"]
    assert {(l["source"], l["target"]): l["weight"] for l in res} == {
        (C + "net", "iac_tfresource_azurerm_virtual_network"): 1.0,
        (C + "net", "iac_tfresource_azurerm_subnet"): 2.0,
        (C + "app", "iac_tfresource_helm_release"): 1.0,
        (C + "app", "iac_tfdata_azurerm_client_config"): 1.0,
    }
    assert edges(g, "requires_provider") == {(C + "net", "iac_tfprovider_hashicorp_azurerm")}
    assert edges(g, "deploys_chart") == {(C + "app", "iac_helmchart_hello")}
    chart = next(n for n in g["nodes"] if n["id"] == "iac_helmchart_hello")
    assert chart["source_file"] == "applications/charts/hello/Chart.yaml" and chart["version"] == "1.0.0"
    net = next(n for n in g["nodes"] if n["id"] == C + "net")
    assert (net["tf_variables"], net["tf_outputs"]) == (1, 1)
    mod_link = next(l for l in g["links"] if l["relation"] == "uses_module" and l["source"] == C + "net")
    assert (mod_link["source_file"], mod_link["source_location"], mod_link["context"]) == \
        ("roots/net/main.tf", "L8", "naming")
    ids = {n["id"] for n in g["nodes"]}
    assert not any("ghost" in i or "fake_type" in i or "ignored_type" in i for i in ids)

    # pipelines: template refs resolved relative to the file; graphify-ignored files are never a source
    P = "iac_pipeline_"
    assert edges(g, "uses_template") == {(P + "azure_pipelines_yml", P + "pipelines_templates_universal_yml")}
    assert not any(n["source_file"].startswith("pipelines/generated/") for n in g["nodes"])
    assert not any(l["source_file"].startswith("pipelines/generated/") for l in g["links"])

    # profiles / environments
    assert edges(g, "enables") == {("iac_profile_small", C + "net"), ("iac_profile_small", C + "app"),
                                   ("iac_environment_dev", C + "obs")}
    assert edges(g, "uses_profile") == {("iac_environment_dev", "iac_profile_small")}


def test_deterministic_and_native_links(tree: Path) -> None:
    base = {"nodes": [
        {"id": "terraform_roots_net_abc_directory", "type": "module", "_terraform_directory": "roots/net",
         "label": "Terraform module: roots/net", "source_file": "roots/net/main.tf"},
        {"id": "catalog_contracts_net_v2_schema_json", "label": "net.v2.schema.json",
         "source_file": "catalog/contracts/net.v2.schema.json"},
    ], "links": []}
    a, b = build(tree, base), build(tree, base)
    assert json.dumps(a) == json.dumps(b)
    assert ("iac_component_net", "terraform_roots_net_abc_directory") in edges(a, "implemented_by")
    assert ("iac_contract_net", "catalog_contracts_net_v2_schema_json") in edges(a, "has_schema")


def test_merge_replaces_layer(tree: Path) -> None:
    base = {"directed": False, "multigraph": False, "graph": {}, "hyperedges": [],
            "built_at_commit": "abc",
            "nodes": [{"id": "ast_a", "label": "a", "file_type": "code", "source_file": "a.py"},
                      {"id": "iac_component_stale", "label": "stale", "file_type": "code", "source_file": "x"}],
            "links": [{"source": "ast_a", "target": "iac_component_stale", "relation": "uses"},
                      {"source": "ast_a", "target": "ast_a2", "relation": "calls"}]}
    layer = build(tree)
    once = ig.merge_into(base, layer)
    twice = ig.merge_into(once, layer)
    assert once == twice, "merge must be idempotent"
    ids = {n["id"] for n in once["nodes"]}
    assert "ast_a" in ids and "iac_component_stale" not in ids and "iac_component_net" in ids
    assert {"source": "ast_a", "target": "ast_a2", "relation": "calls"} in once["links"]
    assert not any(l["target"] == "iac_component_stale" for l in once["links"])
    assert once["built_at_commit"] == "abc"


def test_slug_collisions_are_disambiguated() -> None:
    g = ig.Graph()
    a = g.add_node("tfmodule", "a-b", "a-b", "x.tf")
    b = g.add_node("tfmodule", "a_b", "a_b", "y.tf")
    assert a == "iac_tfmodule_a_b" and b.startswith("iac_tfmodule_a_b_") and a != b
    assert g.add_node("tfmodule", "a-b", "a-b", "x.tf") == a


def test_ignore_matcher(tmp_path: Path) -> None:
    (tmp_path / ".graphifyignore").write_text("# c\ngraphify-out/\n**/.terraform/\n**/*.lock.hcl\n"
                                             "docs/diagrams/**/*.svg\npipelines/generated/\n")
    ignored = ig.Ignore(tmp_path)
    assert ignored("pipelines/generated/a.yml") and ignored("x/.terraform/m/main.tf")
    assert ignored("a/b/.terraform.lock.hcl") and ignored("docs/diagrams/x/y.svg")
    assert not ignored("pipelines/templates/a.yml") and not ignored("pipelines/generated")
    assert not ignored("docs/diagrams/x/y.mmd")


def test_cli_writes_and_merges(tree: Path, tmp_path: Path) -> None:
    graph = tmp_path / "graph.json"
    graph.write_text(json.dumps({"directed": False, "multigraph": False, "graph": {}, "nodes": [], "links": [],
                                 "hyperedges": []}))
    out = tmp_path / "iac.json"
    assert ig.main(["--repo", str(tree), "--out", str(out), "--merge-into", str(graph)]) == 0
    layer, merged = json.loads(out.read_text()), json.loads(graph.read_text())
    assert len(merged["nodes"]) == len(layer["nodes"]) > 0
    assert ig.main(["--repo", str(tree), "--out", str(out), "--merge-into", str(tmp_path / "missing.json")]) == 2


@pytest.mark.skipif(shutil.which("graphify") is None, reason="graphify CLI not installed (optional)")
def test_graphify_loads_layer(tree: Path, tmp_path: Path) -> None:
    pin = (REPO / "tools/graphify/VERSION").read_text().strip()
    version = subprocess.run(["graphify", "--version"], capture_output=True, text=True).stdout.split()
    if version[-1:] != [pin]:
        pytest.skip(f"graphify {version} is not the pinned {pin}")
    out = tmp_path / "iac.json"
    out.write_text(json.dumps(build(tree)))
    r = subprocess.run(["graphify", "god-nodes", "--graph", str(out), "--top", "3"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "component" in r.stdout


def test_smoke_real_catalog() -> None:
    start = time.monotonic()
    g = build(REPO)
    elapsed = time.monotonic() - start
    assert_schema(g)
    registry = yaml.safe_load((REPO / "catalog/components.yaml").read_text())["components"]
    ids = {n["id"] for n in g["nodes"]}
    for c in registry:
        assert f"iac_component_{ig.slug(c['id'])}" in ids, c["id"]
    # every contract a component produces is a node, with its producer
    produced = edges(g, "produces_contract")
    for c in registry:
        for name in c.get("produces") or []:
            assert (f"iac_component_{ig.slug(c['id'])}", f"iac_contract_{ig.slug(name)}") in produced
    consumers = {s for s, t in edges(g, "consumes_contract") if t == "iac_contract_obs_telemetry_transport"}
    expected = {f"iac_component_{ig.slug(c['id'])}" for c in registry
                if "obs-telemetry-transport" in (c.get("consumes") or []) + (c.get("optional_consumes") or [])}
    assert consumers == expected and len(expected) >= 5
    # every terraform component root resolves to scanned .tf content
    tf_roots = [c for c in registry if c.get("kind", "terraform") == "terraform"]
    declaring = {s for s, _ in edges(g, "declares_resource")} | {s for s, _ in edges(g, "uses_module")}
    missing = [c["id"] for c in tf_roots if f"iac_component_{ig.slug(c['id'])}" not in declaring]
    assert len(missing) <= len(tf_roots) // 4, f"roots with no resources/modules: {missing}"
    ignored = ig.Ignore(REPO)
    assert not [n["source_file"] for n in g["nodes"] if ignored(n["source_file"])]
    assert len(g["nodes"]) < 5000 and len(g["links"]) < 20000, "keep the IaC layer small"
    assert elapsed < 30
