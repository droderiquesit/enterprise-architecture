#!/usr/bin/env python3
"""Generate pipelines/generated/component-stages.yml from catalog/components.yaml.

    python3 tools/pipeline/generate.py            # (re)write the file
    python3 tools/pipeline/generate.py --check    # exit 1 when the checked-in file is stale

The file is checked in; the Validate stage fails when regeneration differs.

Generated stages (after Select/Validate/Security, which live in pipelines/templates/universal.yml):
  Build      one job per artifact component: resolve the image/package for the source fingerprint
             (first environment of a promotion chain: build if missing) or promote it from the
             previous environment (later environments: never build)
  P_<x>      Plan stage per Terraform component (pipeline: manual components excluded); PLAN identity,
             no environment, so no approval is requested before the plan exists
  C_<x>      Apply stage per component: deployment job on environment lab-<env> (approvals, exclusive
             lock, required template). Approvers see the published plan summary of P_<x> first.
  Retire, Verify, Drift, Evidence

Conditions (evaluated in tests with tools/pipeline/conditions.py):
  P_x: and(not(canceled()), <Select/Validate/Security succeeded>, eq(sel_x,'true'),
           <artifacts of x ready>, <for each DIRECT upstream u: upstream_ok(u)>)
  upstream_ok(u) = and(or(in(P_u.result, 'Succeeded','SucceededWithIssues'),
                          and(eq(P_u.result,'Skipped'), ne(sel_u,'true'))),
                       in(C_u.result, 'Succeeded','SucceededWithIssues','Skipped'))
       -> an unselected upstream does not block; a selected upstream whose plan failed / was skipped
          (because its own upstream failed) blocks; a failed / canceled / rejected apply blocks.
          Direct upstream suffices: an infrastructure change selects every transitive consumer, so a
          failure propagates stage by stage (each selected-but-skipped stage blocks its consumers).
  C_x: and(not(canceled()), ne(variables['DRY_RUN'],'true'), in(P_x.result,'Succeeded','SucceededWithIssues'),
           eq(P_x.outputs['Plan.plan.has_changes'],'true'), eq(apply_x,'true'))
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import sys
from pathlib import Path
from typing import Dict, List

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.graph import Graph  # noqa: E402
from tools.changeset.registry import Component, Registry, load_registry, var_id  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

OUTPUT = "pipelines/generated/component-stages.yml"
GATE_STAGES = ("Select", "Validate", "Security")
OK = "'Succeeded', 'SucceededWithIssues'"
LANGUAGE_HINTS = {"svc-traffic": "python", "svc-logicapps": "workflow"}
# Roots whose Terraform providers/variables need Datadog keys (Key Vault-linked variable group):
#   provider -> DD_API_KEY / DD_APP_KEY for the datadog provider; tfvar -> TF_VAR_datadog_api_key (ephemeral)
DATADOG = {"obs-prereqs": "provider", "obs-azure-integration": "provider", "obs-monitoring": "provider",
           "obs-kubernetes": "tfvar"}


def sel(cid: str) -> str:
    return f"dependencies.Select.outputs['select.detect.sel_{var_id(cid)}']"


def apply_flag(cid: str) -> str:
    return f"dependencies.Select.outputs['select.detect.apply_{var_id(cid)}']"


def plan_stage(cid: str) -> str:
    return "P_" + var_id(cid)


def apply_stage(cid: str) -> str:
    return "C_" + var_id(cid)


def gate_terms() -> List[str]:
    return [f"in(dependencies.{s}.result, {OK})" for s in GATE_STAGES]


def upstream_term(cid: str) -> str:
    p, c = plan_stage(cid), apply_stage(cid)
    return (f"and(or(in(dependencies.{p}.result, {OK}), and(eq(dependencies.{p}.result, 'Skipped'), "
            f"ne({sel(cid)}, 'true'))), in(dependencies.{c}.result, {OK}, 'Skipped'))")


def artifact_ready(cid: str) -> str:
    return f"eq(dependencies.Build.outputs['B_{var_id(cid)}.ready.ready'], 'true')"


def plan_condition(c: Component, upstream: List[Component]) -> str:
    terms = ["not(canceled())", *gate_terms(), f"eq({sel(c.id)}, 'true')"]
    terms += [artifact_ready(a) for a in c.artifacts]
    terms += [upstream_term(u.id) for u in upstream]
    return "and(" + ", ".join(terms) + ")"


def apply_condition(c: Component) -> str:
    p = plan_stage(c.id)
    return ("and(not(canceled()), ne(variables['DRY_RUN'], 'true'), "
            f"in(dependencies.{p}.result, {OK}), eq(dependencies.{p}.outputs['Plan.plan.has_changes'], 'true'), "
            f"eq({apply_flag(c.id)}, 'true'))")


# kept for callers/tests written against the single-stage layout
component_condition = plan_condition


def language_of(c: Component) -> str:
    if c.id in LANGUAGE_HINTS:
        return LANGUAGE_HINTS[c.id]
    if (c.artifact or {}).get("type") == "static-bundle":
        return "node"
    joined = " ".join(c.inputs)
    if "applications/shared/dotnet" in joined:
        return "dotnet"
    if "applications/shared/python" in joined:
        return "python"
    return "generic"


def direct_upstream(graph: Graph, reg: Registry, c: Component) -> List[Component]:
    return [reg.get(u) for u in sorted(graph.upstream(c.id)) if reg.get(u).deployable]


def build(reg: Registry, layers: List[str] | None = None) -> dict:
    """`layers` (scaling strategy, README "Scaling"): emit only components of these layers, e.g. one
    generated file per pipeline when a single run would exceed the ADO template limits. Upstream
    components of other layers are then deployed by an earlier pipeline (pipeline resource trigger) and
    are not referenced by conditions."""
    graph = Graph(reg)
    graph.check_acyclic()
    order = [cid for layer in graph.layers() for cid in layer]
    deployables = sorted((c for c in reg if c.deployable and (not layers or c.layer in layers)),
                         key=lambda c: (order.index(c.id), c.id))
    in_scope = {c.id for c in deployables}
    needed = {a for c in deployables for a in c.artifacts}
    artifacts = sorted((c for c in reg if c.is_artifact and (not layers or c.id in needed)), key=lambda c: c.id)
    settings = "${{ parameters.settings }}"
    env = "${{ parameters.environment }}"
    dry = "${{ parameters.dryRun }}"
    pool = {"name": "${{ parameters.settings.deployPool }}"}
    stages: List[dict] = []

    stages.append({
        "stage": "Build",
        "displayName": "Artifacts (build once per source fingerprint / promote)",
        "dependsOn": list(GATE_STAGES),
        "condition": "and(" + ", ".join(["not(canceled())", *gate_terms(),
                                          "eq(dependencies.Select.outputs['select.detect.any_build'], 'true')"]) + ")",
        "pool": pool,
        "jobs": [{
            "template": "../templates/build-artifact.yml",
            "parameters": {
                "component": a.id, "jobName": f"B_{a.var_id}", "componentPath": a.path,
                "artifactName": a.artifact["name"], "formats": [a.artifact["type"], *a.artifact.get("also", [])],
                "language": language_of(a), "timeoutMinutes": a.timeout_minutes, "environment": env,
                "settings": settings,
            },
        } for a in artifacts],
    })

    for c in deployables:
        ups = [u for u in direct_upstream(graph, reg, c) if u.id in in_scope]
        common = {"component": c.id, "componentPath": c.path, "artifacts": list(c.artifacts),
                  "timeoutMinutes": c.timeout_minutes, "environment": env,
                  "datadog": DATADOG.get(c.id, "none"), "settings": settings}
        stages.append({
            "stage": plan_stage(c.id),
            "displayName": f"plan {c.id}",
            "dependsOn": list(GATE_STAGES) + (["Build"] if c.artifacts else [])
                         + [s for u in ups for s in (plan_stage(u.id), apply_stage(u.id))],
            "lockBehavior": "sequential",
            "condition": plan_condition(c, ups),
            "pool": pool,
            "jobs": [{"template": "../templates/terraform-plan.yml", "parameters": dict(common)}],
        })
        stages.append({
            "stage": apply_stage(c.id),
            "displayName": f"apply {c.id}",
            "dependsOn": ["Select", plan_stage(c.id)] + (["Build"] if c.artifacts else []),
            "lockBehavior": "sequential",
            "condition": apply_condition(c),
            "pool": pool,
            "jobs": [{"template": "../templates/terraform-apply.yml", "parameters": dict(common, dryRun=dry)}],
        })

    plans = [plan_stage(c.id) for c in deployables]
    applies = [apply_stage(c.id) for c in deployables]
    select_ok = ["not(canceled())", f"in(dependencies.Select.result, {OK})"]
    no_failure = [f"in(dependencies.{s}.result, {OK}, 'Skipped')" for s in plans + applies]
    stages.append({
        "template": "../templates/retire.yml",
        "parameters": {
            "dependsOn": ["Select", *plans, *applies],
            "condition": "and(" + ", ".join(select_ok + [
                "eq(dependencies.Select.outputs['select.detect.has_retirements'], 'true')", *no_failure]) + ")",
            "environment": env, "dryRun": dry, "settings": settings,
        },
    })
    stages.append({
        "stage": "Verify",
        "displayName": "Smoke + telemetry verification",
        "dependsOn": ["Select", *applies],
        "condition": "and(" + ", ".join(select_ok + [
            "eq(dependencies.Select.outputs['select.detect.any_deploy'], 'true')",
            "ne(dependencies.Select.outputs['select.detect.mode'], 'drift')",
            "ne(variables['DRY_RUN'], 'true')"]) + ")",
        "pool": pool,
        "jobs": [
            {"template": "../templates/smoke.yml", "parameters": {"environment": env, "settings": settings}},
            {"template": "../templates/telemetry-verify.yml", "parameters": {"environment": env, "settings": settings}},
        ],
    })
    stages.append({
        "stage": "Drift",
        "displayName": "Drift report",
        "dependsOn": ["Select", *plans],
        "condition": "and(" + ", ".join(select_ok + ["eq(dependencies.Select.outputs['select.detect.mode'], 'drift')"]) + ")",
        "pool": pool,
        "jobs": [{"template": "../templates/drift.yml", "parameters": {"environment": env, "settings": settings}}],
    })
    stages.append({
        "stage": "Evidence",
        "displayName": "Report, evidence and deployment markers",
        "dependsOn": ["Select", "Build", *plans, *applies, "Retire", "Verify", "Drift"],
        "condition": "and(" + ", ".join(select_ok + [
            "or(eq(dependencies.Select.outputs['select.detect.any_deploy'], 'true'), "
            "eq(dependencies.Select.outputs['select.detect.has_retirements'], 'true'))"]) + ")",
        "pool": pool,
        "jobs": [{"template": "../templates/evidence.yml",
                  "parameters": {"environment": env, "dryRun": dry, "settings": settings}}],
    })
    return {
        "parameters": [
            {"name": "environment", "type": "string"},
            {"name": "dryRun", "type": "boolean", "default": False},
            {"name": "settings", "type": "object"},
        ],
        "stages": stages,
    }


class _Dumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):  # list items indented under keys
        return super().increase_indent(flow, False)


def render(reg: Registry, registry_text: str, layers: List[str] | None = None) -> str:
    body = yaml.dump(build(reg, layers), Dumper=_Dumper, sort_keys=False, width=100000, default_flow_style=False)
    digest = hashlib.sha256(registry_text.encode()).hexdigest()[:16]
    header = (
        "# GENERATED FILE - DO NOT EDIT.\n"
        "# Source: catalog/components.yaml (sha256 prefix " + digest + ")\n"
        "# Regenerate: python3 tools/pipeline/generate.py   (CI fails when this file is stale)\n"
        "# Stage conditions: see tools/pipeline/generate.py docstring; evaluated in tests by\n"
        "# tools/pipeline/conditions.py.\n"
    )
    return header + body


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--output", default=OUTPUT)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--layers", help="comma separated layers (split strategy; default: all)")
    args = ap.parse_args(argv)
    layers = [x for x in (args.layers or "").split(",") if x] or None
    repo = Path(args.repo).resolve()
    tree = WorkTree(repo)
    reg = load_registry(tree)
    text = render(reg, tree.read_text("catalog/components.yaml") or "", layers)
    target = repo / args.output
    n = sum(1 for c in reg if c.deployable)
    if args.check:
        current = target.read_text() if target.exists() else ""
        if current != text:
            diff = difflib.unified_diff(current.splitlines(), text.splitlines(), "checked-in", "regenerated", lineterm="", n=1)
            print("\n".join(list(diff)[:60]))
            print(f"ERROR: {args.output} is stale; run: python3 tools/pipeline/generate.py", file=sys.stderr)
            return 1
        print(f"{args.output} is up to date ({n} components: {2 * n} plan/apply stages)")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    print(f"wrote {args.output}: {n} components ({2 * n} plan/apply stages), "
          f"{sum(1 for c in reg if c.is_artifact)} build jobs")
    return 0


def stage_map(doc: dict) -> Dict[str, dict]:
    return {s["stage"]: s for s in doc["stages"] if "stage" in s}


if __name__ == "__main__":
    sys.exit(main())
