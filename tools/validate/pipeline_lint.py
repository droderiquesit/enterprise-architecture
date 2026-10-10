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
  PL004  component stages use lockBehavior: sequential or settings.stageLockBehavior (variables: runLatest only for the
         CI environment); the pipeline sets lockBehavior: sequential
         (exclusive lock checks on lab-<env> environments queue runs instead of cancelling them)
  PL005  every deployment job targets an environment named lab-<env>[-retire]
  PL006  pipelines/generated/{platform,applications}-stages.yml are up to date with the registry
  PL007  conditions parse with the expression subset evaluated in tests (tools/pipeline/conditions.py)
  PL008  retryCountOnTaskFailure only on idempotent network steps (downloads, tool installs, init, resolve)
  PL009  scripts never enable xtrace (set -x) or echo secret variables; secrets reach steps via env only
  PL010  every job declares timeoutInMinutes (templates may take it from a parameter)
  PL011  scheduled triggers use always: true (drift detection runs even without code changes)
  PL012  every agent job declares cancelTimeoutInMinutes (cleanup / failure records get time to run)
  PL013  every job on a self-hosted pool declares `workspace: clean: all` (no state leaks between runs)
  PL014  entry pipelines (azure-pipelines.yml, azure-pipelines.applications.yml) only `extends:` the universal template
  PL015  no AzureKeyVault@ task and no variable group anywhere (Delinea DSV via tools/secrets/fetch.py only;
         ADR-0001 section 14); PL009 also covers the variables fetch.py sets (registry secret_env, DD_*, TF_VAR_*)
  (PL003 per stage kind: P_<x> checks every dependency's result (Build: its artifacts' readiness outputs);
   C_<x> depends on and checks P_<x> result + has_changes and is skipped on dry runs)
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
RETRY_OK_SCRIPT = re.compile(r"(pip install|install-tools\.sh|setup-agent\.sh|npm ci|tools\.ci tf-mirror)")   # tf-mirror: idempotent download into a mirror dir
SECRET_ECHO = re.compile(r"echo[^\n]*\$\((datadog-[a-z-]+|[A-Za-z_.]*[Ss]ecret[A-Za-z_.]*)\)")
FETCHED_ECHO = re.compile(r"\b(echo|printf)\b[^\n]*\$(\{|\()?(DD_API_KEY|DD_APP_KEY|TF_VAR_[A-Za-z0-9_]+|DSV_CLIENT_SECRET)\b")


def files(repo: Path) -> list[Path]:
    out = [repo / "azure-pipelines.yml", repo / "azure-pipelines.applications.yml"]
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
    for entry in ("azure-pipelines.yml", "azure-pipelines.applications.yml"):
        root = docs.get(entry)
        if root is None:
            continue
        if root.get("lockBehavior") != "sequential":
            errors.append(f"PL004 {entry}: pipeline-level lockBehavior must be 'sequential'")
    # stage locks: runLatest only for the first environment of the promotion chain (CI-deployed dev); test/prod
    # promotions are never superseded silently
    for vf in sorted((repo / "pipelines/variables").glob("*.yml")):
        if vf.name == "tools.yml":
            continue
        vdoc = yaml.safe_load(vf.read_text()) or {}
        vals = {v.get("name"): v.get("value") for v in vdoc.get("variables", []) if isinstance(v, dict)} \
            if isinstance(vdoc.get("variables"), list) else dict(vdoc.get("variables") or {})
        lb = vals.get("stageLockBehavior")
        if lb not in ("sequential", "runLatest"):
            errors.append(f"PL004 pipelines/variables/{vf.name}: stageLockBehavior must be sequential or runLatest (got {lb!r})")
        elif lb == "runLatest" and vals.get("promoteFrom"):
            errors.append(f"PL004 pipelines/variables/{vf.name}: runLatest is only allowed for the CI environment (no promoteFrom)")
        for sch in root.get("schedules") or []:
            if sch.get("always") is not True:
                errors.append(f"PL011 {entry}: schedule '{sch.get('cron')}' must set always: true")
        if "extends" not in root or "stages" in root or "jobs" in root:
            errors.append(f"PL014 {entry}: entry pipelines must only `extends:` pipelines/templates/universal.yml")
        elif not str(root["extends"].get("template", "")).endswith("templates/universal.yml"):
            errors.append(f"PL014 {entry}: must extend pipelines/templates/universal.yml (Required template check)")

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
                    if str(name).startswith("P_"):
                        for d in deps:
                            if d == "Build":
                                # per-artifact readiness instead of the whole Build stage result: an unrelated
                                # artifact failing must not block this component, its own artifacts must
                                if "dependencies.Build.outputs[" not in text:
                                    errors.append(f"PL003 {rel}: stage {name}: does not check its artifacts' Build outputs")
                                continue
                            if f"dependencies.{d}.result" not in text:
                                errors.append(f"PL003 {rel}: stage {name}: does not check dependencies.{d}.result")
                    if str(name).startswith("C_"):
                        plan = "P_" + str(name)[2:]
                        if plan not in deps or f"dependencies.{plan}.result" not in text \
                                or f"dependencies.{plan}.outputs['Plan.plan.has_changes']" not in text:
                            errors.append(f"PL003 {rel}: stage {name}: must depend on and check {plan} (result + has_changes)")
                        if "variables['DRY_RUN']" not in text:
                            errors.append(f"PL003 {rel}: stage {name}: must be skipped on dry runs (variables['DRY_RUN'])")
                    if str(name).startswith(("P_", "C_")) and node.get("lockBehavior") not in (
                            "sequential", "${{ parameters.settings.stageLockBehavior }}"):
                        errors.append(f"PL004 {rel}: stage {name}: lockBehavior must be sequential or settings.stageLockBehavior")
            if kind == "deployment":
                env = node.get("environment")
                env_name = env.get("name") if isinstance(env, dict) else env
                if not isinstance(env_name, str) or not env_name.startswith("lab-"):
                    errors.append(f"PL005 {rel}: deployment {name}: environment must be lab-<env> (got {env_name!r})")
            if kind in ("job", "deployment") and "timeoutInMinutes" not in node:
                errors.append(f"PL010 {rel}: {kind} {name}: missing timeoutInMinutes")
            pool = node.get("pool")
            server = pool == "server"
            hosted = isinstance(pool, dict) and "vmImage" in pool
            if kind in ("job", "deployment") and not server and "cancelTimeoutInMinutes" not in node:
                errors.append(f"PL012 {rel}: {kind} {name}: missing cancelTimeoutInMinutes")
            if kind in ("job", "deployment") and not server and not hosted and not _has_clean_workspace(node):
                errors.append(f"PL013 {rel}: {kind} {name}: self-hosted job without `workspace: clean: all`")
            task_name = str(node.get("task", ""))
            if task_name.startswith("AzureKeyVault@"):
                errors.append(f"PL015 {rel}: AzureKeyVault@ task is forbidden (secrets come from Delinea DSV via tools/secrets/fetch.py)")
            if "group" in node and len(node) == 1:
                errors.append(f"PL015 {rel}: variable group '{node['group']}' is forbidden (no Key Vault-linked groups; DSV + fetch.py)")
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
    gen_stages = [st for rel in ("pipelines/generated/platform-stages.yml", "pipelines/generated/applications-stages.yml")
                  for st in (docs.get(rel) or {}).get("stages", [])]
    for st in gen_stages:
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
            errors.append("PL006 pipelines/generated/*-stages.yml are stale: run python3 tools/pipeline/generate.py")
    return errors


def _has_clean_workspace(node) -> bool:
    if isinstance(node, dict):
        ws = node.get("workspace")
        if isinstance(ws, dict) and ws.get("clean") == "all":
            return True
        pool = node.get("pool")
        if isinstance(pool, dict) and "vmImage" in pool:
            return True
        return any(_has_clean_workspace(v) for k, v in node.items() if str(k).startswith("${{"))
    if isinstance(node, list):
        return any(_has_clean_workspace(v) for v in node)
    return False


def _scan_script(rel: str, body: str, errors: list[str]) -> None:
    for line in body.splitlines():
        s = line.strip()
        if re.match(r"^set\s+-[a-wyz]*x", s) or s == "set -x" or "set -o xtrace" in s:
            errors.append(f"PL009 {rel}: script enables xtrace: {s}")
        if SECRET_ECHO.search(s) or FETCHED_ECHO.search(s):
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
