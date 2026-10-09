#!/usr/bin/env python3
"""Lint the Azure DevOps pipeline (azure-pipelines.yml, pipelines/templates, pipelines/generated).

    python3 tools/validate/pipeline_lint.py

Rules
  PL001  no always() in any stage or job condition; no succeededOrFailed() in stage conditions or on
         deployment jobs (a failed upstream must block deployments)
  PL002  every explicit stage condition is a top-level and(...) containing not(canceled())
  PL003  every component/retire stage checks the result of every stage it depends on
         (dependencies.<stage>.result) - a failed upstream blocks; for Build it checks the readiness
         outputs of exactly its own artifacts (dependencies.Build.outputs['B_<artifact>.ready.ready'])
  PL004  component stages use lockBehavior: sequential; the pipeline sets lockBehavior: sequential
         (exclusive lock checks on lab-<env> environments queue runs instead of cancelling them)
  PL005  every deployment job targets an environment named lab-<env>[-retire]
  PL006  pipelines/generated/component-stages.yml is up to date with the registry
  PL007  conditions parse with the expression subset evaluated in tests (tools/pipeline/conditions.py)
  PL008  retryCountOnTaskFailure only on idempotent network steps (downloads, tool installs, init, resolve)
  PL009  scripts never enable xtrace (set -x) or echo secret variables; secrets reach steps via env only
  PL010  every job declares timeoutInMinutes (templates may take it from a parameter)
  PL011  scheduled triggers use always: true (drift detection runs even without code changes)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.pipeline.conditions import ExpressionError, functions_used, parse, top_level_conjuncts  # noqa: E402

RETRY_OK_TASKS = ("DownloadPipelineArtifact@", "UseDotNet@", "NodeTool@", "UsePythonVersion@")
RETRY_OK_NAMES = {"init", "resolve"}
RETRY_OK_SCRIPT = re.compile(r"(pip install|install-tools\.sh|npm ci)")
SECRET_ECHO = re.compile(r"echo[^\n]*\$\((datadog-[a-z-]+|[A-Za-z_.]*[Ss]ecret[A-Za-z_.]*)\)")


def files(repo: Path) -> list[Path]:
    out = [repo / "azure-pipelines.yml"]
    out += sorted((repo / "pipelines/templates").glob("*.yml"))
    out += sorted((repo / "pipelines/generated").glob("*.yml"))
    return [p for p in out if p.exists()]


def walk(node, visit, ctx=None):
    """Visit every mapping, unwrapping ${{ if }} / ${{ each }} conditional insertion keys."""
    if isinstance(node, dict):
        visit(node, ctx)
        for k, v in node.items():
            walk(v, visit, ctx)
    elif isinstance(node, list):
        for v in node:
            walk(v, visit, ctx)


def is_template_expr(s: str) -> bool:
    return isinstance(s, str) and s.strip().startswith("${{")


def strip_template_exprs(s: str) -> str:
    # replace ${{ ... }} (used inside variable names) by a placeholder identifier
    return re.sub(r"\$\{\{[^}]*\}\}", "X", s)


def lint(repo: Path, check_generated: bool = True) -> list[str]:
    errors: list[str] = []
    docs = {}
    for p in files(repo):
        rel = p.relative_to(repo).as_posix()
        try:
            docs[rel] = yaml.safe_load(p.read_text())
        except yaml.YAMLError as exc:
            errors.append(f"{rel}: YAML parse error: {exc}")
    root = docs.get("azure-pipelines.yml") or {}
    if root.get("lockBehavior") != "sequential":
        errors.append("PL004 azure-pipelines.yml: pipeline-level lockBehavior must be 'sequential'")
    for sch in root.get("schedules") or []:
        if sch.get("always") is not True:
            errors.append(f"PL011 azure-pipelines.yml: schedule '{sch.get('cron')}' must set always: true")

    for rel, doc in docs.items():
        def visit(node, _ctx, rel=rel):
            cond = node.get("condition")
            kind = "stage" if "stage" in node else ("deployment" if "deployment" in node else ("job" if "job" in node else None))
            name = node.get("stage") or node.get("deployment") or node.get("job")
            if kind and isinstance(cond, str) and not is_template_expr(cond):
                text = strip_template_exprs(cond)
                try:
                    used = functions_used(text)
                except ExpressionError as exc:
                    errors.append(f"PL007 {rel}: {kind} {name}: condition does not parse: {exc}")
                    used = set()
                if "always" in used:
                    errors.append(f"PL001 {rel}: {kind} {name}: always() is forbidden")
                if kind in ("stage", "deployment") and "succeededorfailed" in used:
                    errors.append(f"PL001 {rel}: {kind} {name}: succeededOrFailed() is forbidden here")
                if kind == "stage":
                    conj = top_level_conjuncts(text) or []
                    if not text.replace(" ", "").startswith("and(") or "not(canceled())" not in text.replace(" ", ""):
                        errors.append(f"PL002 {rel}: stage {name}: condition must be and(not(canceled()), ...)")
                    elif "not" not in conj:
                        errors.append(f"PL002 {rel}: stage {name}: not(canceled()) must be a top-level conjunct")
                    deps = node.get("dependsOn") or []
                    deps = [deps] if isinstance(deps, str) else deps
                    is_component = str(name).startswith("C_")
                    if is_component:
                        for d in deps:
                            if d == "Build":
                                # per-artifact readiness instead of the whole Build stage result: an unrelated
                                # artifact failing must not block this component, its own artifacts must
                                if "dependencies.Build.outputs[" not in text:
                                    errors.append(f"PL003 {rel}: stage {name}: does not check its artifacts' Build outputs")
                                continue
                            if f"dependencies.{d}.result" not in text:
                                errors.append(f"PL003 {rel}: stage {name}: does not check dependencies.{d}.result")
                        if node.get("lockBehavior") != "sequential":
                            errors.append(f"PL004 {rel}: stage {name}: lockBehavior must be sequential")
            if kind == "deployment":
                env = node.get("environment")
                env_name = env.get("name") if isinstance(env, dict) else env
                if not isinstance(env_name, str) or not env_name.startswith("lab-"):
                    errors.append(f"PL005 {rel}: deployment {name}: environment must be lab-<env> (got {env_name!r})")
            if kind in ("job", "deployment") and "timeoutInMinutes" not in node:
                errors.append(f"PL010 {rel}: {kind} {name}: missing timeoutInMinutes")
            if "retryCountOnTaskFailure" in node:
                task = str(node.get("task", ""))
                script = str(node.get("script", "") or node.get("bash", ""))
                inline = str((node.get("inputs") or {}).get("inlineScript", ""))
                ok = (task.startswith(RETRY_OK_TASKS) or node.get("name") in RETRY_OK_NAMES
                      or bool(RETRY_OK_SCRIPT.search(script)) or bool(RETRY_OK_SCRIPT.search(inline)))
                if not ok:
                    errors.append(f"PL008 {rel}: step '{node.get('displayName') or task or script[:40]}' retries a non-idempotent step")
            for key in ("script", "bash"):
                body = node.get(key)
                if isinstance(body, str):
                    _scan_script(rel, body, errors)
            inline = (node.get("inputs") or {}).get("inlineScript") if isinstance(node.get("inputs"), dict) else None
            if isinstance(inline, str):
                _scan_script(rel, inline, errors)

        walk(doc, visit)

    # retire stage condition comes from the generated file as a parameter
    gen = docs.get("pipelines/generated/component-stages.yml") or {}
    for st in gen.get("stages", []):
        if st.get("template", "").endswith("retire.yml"):
            p = st.get("parameters", {})
            cond = p.get("condition", "")
            for d in p.get("dependsOn", []):
                if d != "Select" and f"dependencies.{d}.result" not in cond:
                    errors.append(f"PL003 generated: Retire does not check dependencies.{d}.result")
            if "not(canceled())" not in cond or "always()" in cond:
                errors.append("PL002 generated: Retire condition must include not(canceled()) and no always()")
    if check_generated:
        proc = subprocess.run([sys.executable, str(repo / "tools/pipeline/generate.py"), "--repo", str(repo), "--check"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            errors.append("PL006 pipelines/generated/component-stages.yml is stale: run python3 tools/pipeline/generate.py")
    return errors


def _scan_script(rel: str, body: str, errors: list[str]) -> None:
    for line in body.splitlines():
        s = line.strip()
        if re.match(r"^set\s+-[a-wyz]*x", s) or s == "set -x" or "set -o xtrace" in s:
            errors.append(f"PL009 {rel}: script enables xtrace: {s}")
        if SECRET_ECHO.search(s):
            errors.append(f"PL009 {rel}: script echoes a secret variable: {s}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--skip-generated-check", action="store_true")
    args = ap.parse_args(argv)
    errors = lint(Path(args.repo).resolve(), not args.skip_generated_check)
    for e in errors:
        print(f"ERROR: {e}")
    print(f"pipeline lint: {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
