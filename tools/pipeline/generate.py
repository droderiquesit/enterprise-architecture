#!/usr/bin/env python3
"""Generate pipelines/generated/component-stages.yml from catalog/components.yaml.

    python3 tools/pipeline/generate.py            # (re)write the file
    python3 tools/pipeline/generate.py --check    # exit 1 when the checked-in file is stale

The file is checked in; the Validate stage fails when regeneration differs.

Generated stages (all after Select/Validate/Security, which live in azure-pipelines.yml):
  Build            one job per artifact component (resolve existing digest for the source
                   fingerprint, else build + push by digest)
  C_<component>    one stage per Terraform component (pipeline: manual components excluded):
                   Plan job -> Apply deployment job (environment lab-<env>, approvals)
  Retire           scheduled retirements (environment lab-<env>-retire)
  Verify           smoke + telemetry verification
  Drift            drift report (drift mode)
  Evidence         deployment report, evidence upload, deployment markers

Stage condition of C_x (see tools/pipeline/conditions.py for the evaluator used in tests):
  and(not(canceled()),
      in(dependencies.Select.result, 'Succeeded', 'SucceededWithIssues'),   (same for Validate, Security)
      eq(dependencies.Select.outputs['select.detect.sel_x'], 'true'),
      eq(dependencies.Build.outputs['B_<artifact>.ready.ready'], 'true'),   per artifact of x
      or(in(dependencies.C_u.result, 'Succeeded', 'SucceededWithIssues'),
         and(eq(dependencies.C_u.result, 'Skipped'),
             ne(dependencies.Select.outputs['select.detect.sel_u'], 'true'))) per transitive upstream u)
An upstream that was not selected (Skipped) does not block; an upstream that was selected but
failed, was canceled, or was itself skipped because *its* upstream failed, blocks. dependsOn lists
the transitive upstream so the rule holds across unselected intermediate stages.
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
OK_RESULTS = "'Succeeded', 'SucceededWithIssues'"
LANGUAGE_HINTS = {"svc-traffic": "python", "svc-logicapps": "workflow"}


def sel(cid: str) -> str:
    return f"dependencies.Select.outputs['select.detect.sel_{var_id(cid)}']"


def gate_terms() -> List[str]:
    return [f"in(dependencies.{s}.result, {OK_RESULTS})" for s in GATE_STAGES]


def upstream_term(stage: str, cid: str) -> str:
    return (f"or(in(dependencies.{stage}.result, {OK_RESULTS}), "
            f"and(eq(dependencies.{stage}.result, 'Skipped'), ne({sel(cid)}, 'true')))")


def artifact_ready(cid: str) -> str:
    return f"eq(dependencies.Build.outputs['B_{var_id(cid)}.ready.ready'], 'true')"


def component_condition(c: Component, upstream: List[Component]) -> str:
    terms = ["not(canceled())", *gate_terms(), f"eq({sel(c.id)}, 'true')"]
    terms += [artifact_ready(a) for a in c.artifacts]
    terms += [upstream_term(u.stage_name, u.id) for u in upstream]
    return "and(" + ", ".join(terms) + ")"


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


def deploy_components(reg: Registry) -> List[Component]:
    return [c for c in reg if c.deployable]


def transitive_upstream_stages(graph: Graph, reg: Registry, c: Component) -> List[Component]:
    ups = graph.transitive_upstream(c.id)
    return [reg.get(u) for u in sorted(ups) if reg.get(u).deployable]


def build(reg: Registry) -> dict:
    graph = Graph(reg)
    graph.check_acyclic()
    order = [cid for layer in graph.layers() for cid in layer]
    deployables = sorted(deploy_components(reg), key=lambda c: (order.index(c.id), c.id))
    artifacts = sorted((c for c in reg if c.is_artifact), key=lambda c: c.id)
    settings = "${{ parameters.settings }}"
    env = "${{ parameters.environment }}"
    dry = "${{ parameters.dryRun }}"
    stages: List[dict] = []

    stages.append({
        "stage": "Build",
        "displayName": "Build artifacts (once per source fingerprint)",
        "dependsOn": list(GATE_STAGES),
        "condition": "and(" + ", ".join(["not(canceled())", *gate_terms(),
                                          "eq(dependencies.Select.outputs['select.detect.any_build'], 'true')"]) + ")",
        "pool": {"name": "${{ parameters.settings.deployPool }}"},
        "jobs": [{
            "template": "../templates/build-artifact.yml",
            "parameters": {
                "component": a.id,
                "jobName": f"B_{a.var_id}",
                "componentPath": a.path,
                "artifactName": a.artifact["name"],
                "formats": [a.artifact["type"], *a.artifact.get("also", [])],
                "language": language_of(a),
                "timeoutMinutes": a.timeout_minutes,
                "environment": env,
                "settings": settings,
            },
        } for a in artifacts],
    })

    for c in deployables:
        ups = transitive_upstream_stages(graph, reg, c)
        depends = list(GATE_STAGES) + (["Build"] if c.artifacts else []) + [u.stage_name for u in ups]
        stages.append({
            "stage": c.stage_name,
            "displayName": f"{c.id}",
            "dependsOn": depends,
            "lockBehavior": "sequential",
            "condition": component_condition(c, ups),
            "pool": {"name": "${{ parameters.settings.deployPool }}"},
            "variables": {"componentId": c.id},
            "jobs": [
                {"template": "../templates/terraform-plan.yml",
                 "parameters": {"component": c.id, "componentPath": c.path, "artifacts": list(c.artifacts),
                                "timeoutMinutes": c.timeout_minutes, "environment": env, "dryRun": dry,
                                "settings": settings}},
                {"template": "../templates/terraform-apply.yml",
                 "parameters": {"component": c.id, "componentPath": c.path, "artifacts": list(c.artifacts),
                                "timeoutMinutes": c.timeout_minutes, "environment": env, "dryRun": dry,
                                "settings": settings}},
            ],
        })

    all_c = [c.stage_name for c in deployables]
    no_failure = [f"in(dependencies.{s}.result, 'Succeeded', 'SucceededWithIssues', 'Skipped')" for s in all_c]
    stages.append({
        "template": "../templates/retire.yml",
        "parameters": {
            "dependsOn": ["Select", *all_c],
            "condition": "and(" + ", ".join([
                "not(canceled())", f"in(dependencies.Select.result, {OK_RESULTS})",
                "eq(dependencies.Select.outputs['select.detect.has_retirements'], 'true')", *no_failure]) + ")",
            "environment": env, "dryRun": dry, "settings": settings,
        },
    })
    after = ["Select", "Build", *all_c]
    select_ok = ["not(canceled())", f"in(dependencies.Select.result, {OK_RESULTS})"]
    stages.append({
        "stage": "Verify",
        "displayName": "Smoke + telemetry verification",
        "dependsOn": after,
        "condition": "and(" + ", ".join(select_ok + [
            "eq(dependencies.Select.outputs['select.detect.any_deploy'], 'true')",
            "ne(dependencies.Select.outputs['select.detect.mode'], 'drift')"]) + ")",
        "pool": {"name": "${{ parameters.settings.deployPool }}"},
        "jobs": [
            {"template": "../templates/smoke.yml", "parameters": {"environment": env, "settings": settings}},
            {"template": "../templates/telemetry-verify.yml", "parameters": {"environment": env, "settings": settings}},
        ],
    })
    stages.append({
        "stage": "Drift",
        "displayName": "Drift report",
        "dependsOn": after,
        "condition": "and(" + ", ".join(select_ok + ["eq(dependencies.Select.outputs['select.detect.mode'], 'drift')"]) + ")",
        "pool": {"name": "${{ parameters.settings.deployPool }}"},
        "jobs": [{"template": "../templates/drift.yml", "parameters": {"environment": env, "settings": settings}}],
    })
    stages.append({
        "stage": "Evidence",
        "displayName": "Report, evidence and deployment markers",
        "dependsOn": ["Select", "Build", *all_c, "Retire", "Verify", "Drift"],
        "condition": "and(" + ", ".join(select_ok + [
            "or(eq(dependencies.Select.outputs['select.detect.any_deploy'], 'true'), "
            "eq(dependencies.Select.outputs['select.detect.has_retirements'], 'true'))"]) + ")",
        "pool": {"name": "${{ parameters.settings.deployPool }}"},
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


def render(reg: Registry, registry_text: str) -> str:
    body = yaml.dump(build(reg), Dumper=_Dumper, sort_keys=False, width=100000, default_flow_style=False)
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
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    tree = WorkTree(repo)
    reg = load_registry(tree)
    text = render(reg, tree.read_text("catalog/components.yaml") or "")
    target = repo / args.output
    if args.check:
        current = target.read_text() if target.exists() else ""
        if current != text:
            diff = difflib.unified_diff(current.splitlines(), text.splitlines(), "checked-in", "regenerated", lineterm="", n=1)
            print("\n".join(list(diff)[:60]))
            print(f"ERROR: {args.output} is stale; run: python3 tools/pipeline/generate.py", file=sys.stderr)
            return 1
        print(f"{args.output} is up to date ({sum(1 for c in reg if c.deployable)} component stages)")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    print(f"wrote {args.output}: {sum(1 for c in reg if c.deployable)} component stages, "
          f"{sum(1 for c in reg if c.is_artifact)} build jobs")
    return 0


def stage_map(doc: dict) -> Dict[str, dict]:
    return {s["stage"]: s for s in doc["stages"] if "stage" in s}


if __name__ == "__main__":
    sys.exit(main())
