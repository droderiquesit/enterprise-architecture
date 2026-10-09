#!/usr/bin/env python3
"""Template-contract, limits and environment-consistency lint for the Azure DevOps pipelines.

    python3 tools/validate/pipeline_templates.py [--repo .] [--json]

Follows every `template:` reference exactly like Azure Pipelines resolves it (relative to the file that
contains the reference; a leading `/` means the repository root; `@self` is this repository; other
`@repo` references are external and skipped) starting from the entry pipelines.

Template contract
  TC001 referenced template file exists
  TC002 every parameter passed to a template is declared by it
  TC003 every declared parameter without a default is passed
  TC004 statically known (literal) values match the declared `type` and `values`
  TC005 every `parameters.<name>` used inside a template is declared by it
  TC006 every `parameters.settings.<key>` used by any template is provided by the settings object the
        universal template builds (no silently empty compile-time values)
  TC007 stage names unique after expansion; stage `dependsOn` targets exist
  TC008 job names unique within each stage after expansion; job `dependsOn` targets exist in the stage
  TC009 scripts never enable xtrace or echo secret variables (datadog-*, *secret*, *_KEY env vars)
Azure Pipelines limits (Learn, "Templates - imposed limits"; "Stages" - a stage can have up to 256 jobs)
  LIM001 distinct YAML files per pipeline        limit 100   -> fail above 80
  LIM002 template nesting depth                  limit 100   -> fail above 20
  LIM003 expanded YAML size (estimate)           limit 20 MB parse memory, "typically 600 KB - 2 MB on disk"
                                                             -> fail above 1,000,000 bytes, warn above 600,000
  LIM004 jobs per stage (incl. validate matrix legs) limit 256 -> fail above 200
  LIM005 stages per run: no documented limit -> warn above 300 (UI and queueing become unwieldy)
Entry pipelines
  ENT001 exactly two entry pipelines exist: azure-pipelines.yml (platform) and azure-pipelines.applications.yml
  ENT002 both only `extends:` pipelines/templates/universal.yml with their scope
  ENT003 the applications pipeline is triggered by successful platform runs (resources.pipelines)
  ENT004 the platform pipeline triggers on observability-v* tags (release stage)
Environments / promotion
  ENV001 every environment in environments/promotion.yaml has environments/<env>/environment.yaml and
         pipelines/variables/<env>.yml, and no stray environment exists without a chain entry
  ENV002 both entries: `environment` values == all chain environments (default = the ci_trigger env) and
         `mode` values == the union of allowed_modes
  ENV003 pipelines/variables/<env>.yml promoteFrom / promoteFromStateStorageAccount / promoteFromContainerRegistry
         match the chain and the source environment's own variables
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

ENTRY_FILES = ("azure-pipelines.yml", "azure-pipelines.applications.yml")
ENTRY_SCOPES = {"azure-pipelines.yml": "platform", "azure-pipelines.applications.yml": "applications"}
TEMPLATE_DIRS = ("pipelines/templates",)
LIMITS = {"files": 80, "depth": 20, "size_fail": 1_000_000, "size_warn": 600_000, "jobs_per_stage": 200,
          "stages_warn": 300}
PARAM_USE_RE = re.compile(r"parameters(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[\s*'([^']+)'\s*\])")
SETTINGS_USE_RE = re.compile(r"parameters\.settings\.([A-Za-z_][A-Za-z0-9_]*)")
SECRET_ECHO_RE = re.compile(r"\b(echo|printf)\b[^\n]*(\$\((datadog-[a-z-]+|[A-Za-z_.-]*[Ss]ecret[A-Za-z_.-]*)\)|\$\{?(DD_API_KEY|DD_APP_KEY|SYSTEM_ACCESSTOKEN|ARM_CLIENT_SECRET|TF_VAR_datadog_api_key)\b)")
XTRACE_RE = re.compile(r"^\s*set\s+(-[A-Za-wyz]*x[A-Za-z]*|-o\s+xtrace)\b", re.M)


@dataclass
class Finding:
    rule: str
    file: str
    message: str
    level: str = "error"

    def __str__(self) -> str:
        return f"{self.level.upper()} {self.rule} {self.file}: {self.message}"


@dataclass
class Report:
    findings: List[Finding] = field(default_factory=list)
    metrics: Dict[str, dict] = field(default_factory=dict)

    def add(self, rule, file, message, level="error"):
        self.findings.append(Finding(rule, file, message, level))

    @property
    def errors(self) -> List[Finding]:
        return [f for f in self.findings if f.level == "error"]


# ------------------------------------------------------------------ loading
_cache: Dict[Path, object] = {}


def load_yaml(path: Path):
    if path not in _cache:
        _cache[path] = yaml.safe_load(path.read_text())
    return _cache[path]


def strip_comments(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#"))


def body_size(doc) -> int:
    """Approximate expanded size contributed by one inclusion: the document without its `parameters`
    declarations (they do not appear in the expanded pipeline), normalised YAML without comments."""
    if isinstance(doc, dict):
        doc = {k: v for k, v in doc.items() if k != "parameters"}
    return len(yaml.safe_dump(doc, sort_keys=False, width=100000, default_flow_style=False))


def expand_ref(repo: Path, ref: str, scope: Optional[str] = None) -> List[str]:
    """Template paths containing ${{ parameters.environment }} are checked for every environment;
    ${{ parameters.scope }} is the scope of the entry pipeline being walked."""
    if scope:
        ref = re.sub(r"\$\{\{\s*parameters\.scope\s*\}\}", scope, ref)
    if "${{" not in ref:
        return [ref]
    m = re.search(r"\$\{\{\s*parameters\.environment\s*\}\}", ref)
    if not m:
        return []
    try:
        from tools.config.promotion import load

        envs = sorted(load(repo))
    except Exception:  # noqa: BLE001 - promotion problems are reported by check_environments
        envs = [p.stem for p in sorted((repo / "pipelines/variables").glob("*.yml")) if p.stem != "tools"]
    return [ref[:m.start()] + e + ref[m.end():] for e in envs]


def resolve_ref(repo: Path, including: Path, ref: str) -> Optional[Path]:
    """ADO template path resolution. None for templates in other repositories."""
    ref = ref.strip()
    if "@" in ref:
        ref, alias = ref.rsplit("@", 1)
        if alias != "self":
            return None
    if ref.startswith("/"):
        return (repo / ref.lstrip("/")).resolve()
    return (including.parent / ref).resolve()


def declared_params(doc) -> Dict[str, dict]:
    params = (doc or {}).get("parameters") if isinstance(doc, dict) else None
    out = {}
    if isinstance(params, list):
        for p in params:
            if isinstance(p, dict) and "name" in p:
                out[p["name"]] = p
    elif isinstance(params, dict):  # legacy `parameters: {name: default}` form
        for k, v in params.items():
            out[k] = {"name": k, "type": "object", "default": v}
    return out


def iter_template_refs(node, path=()):
    """Yield (mapping_with_template_key, parent_list_kind) for every `template:` reference."""
    if isinstance(node, dict):
        if "template" in node and isinstance(node["template"], str):
            yield node, path
        for k, v in node.items():
            yield from iter_template_refs(v, path + (str(k),))
    elif isinstance(node, list):
        for v in node:
            yield from iter_template_refs(v, path)


def is_expr(v) -> bool:
    return isinstance(v, str) and ("${{" in v or "$[" in v or "$(" in v)


def type_ok(value, spec: dict) -> Optional[str]:
    if is_expr(value):
        return None
    t = spec.get("type", "string")
    ok = True
    if t == "string":
        ok = isinstance(value, (str, int, float, bool))
    elif t == "number":
        ok = isinstance(value, (int, float)) and not isinstance(value, bool) or (isinstance(value, str) and re.fullmatch(r"-?\d+(\.\d+)?", value))
    elif t == "boolean":
        ok = isinstance(value, bool) or (isinstance(value, str) and value.lower() in ("true", "false"))
    elif t in ("stepList", "jobList", "stageList", "deploymentList"):
        ok = isinstance(value, list)
    elif t in ("step", "job", "stage", "deployment"):
        ok = isinstance(value, dict)
    if not ok:
        return f"value {value!r} is not a {t}"
    if spec.get("values") and not isinstance(value, (list, dict)) and str(value) not in [str(v) for v in spec["values"]]:
        return f"value {value!r} not in allowed values {spec['values']}"
    return None


# --------------------------------------------------------------- the walker
class Walker:
    def __init__(self, repo: Path, report: Report):
        self.repo = repo
        self.report = report

    def rel(self, p: Path) -> str:
        try:
            return p.relative_to(self.repo).as_posix()
        except ValueError:
            return str(p)

    def walk(self, entry: Path, scope: Optional[str] = None) -> dict:
        files = set()
        max_depth = 0
        size = 0
        stack: List[Tuple[Path, int]] = []

        def visit(path: Path, depth: int) -> int:
            nonlocal max_depth
            files.add(path)
            max_depth = max(max_depth, depth)
            if depth > LIMITS["depth"] + 5:
                return 0
            doc = load_yaml(path)
            total = body_size(doc)
            for ref_node, _ctx in iter_template_refs(doc):
                targets = []
                for ref in expand_ref(self.repo, ref_node["template"], scope):
                    target = resolve_ref(self.repo, path, ref)
                    if target is None:
                        continue
                    if not target.exists():
                        self.report.add("TC001", self.rel(path), f"template '{ref}' not found ({self.rel(target)})")
                        continue
                    targets.append(target)
                for i, target in enumerate(targets):
                    self.check_call(path, ref_node, target)
                    size = visit(target, depth + 1)
                    if i == 0:          # parameterised path (one per environment): count one instance
                        total += size
            return total

        size = visit(entry.resolve(), 0)
        return {"files": len(files), "depth": max_depth, "expanded_bytes": size}

    # -------------------------------------------------------- call contract
    def check_call(self, caller: Path, ref_node: dict, target: Path) -> None:
        tdoc = load_yaml(target)
        declared = declared_params(tdoc)
        passed = ref_node.get("parameters") or {}
        where = f"{self.rel(caller)} -> {self.rel(target)}"
        if not isinstance(passed, dict):
            if not is_expr(passed):
                self.report.add("TC002", where, "parameters must be a mapping")
            return
        for name, value in passed.items():
            if name.startswith("${{"):
                continue
            if name not in declared:
                self.report.add("TC002", where, f"passes undeclared parameter '{name}'")
                continue
            problem = type_ok(value, declared[name])
            if problem:
                self.report.add("TC004", where, f"parameter '{name}': {problem}")
        for name, spec in declared.items():
            if "default" not in spec and name not in passed:
                self.report.add("TC003", where, f"required parameter '{name}' (no default) is not passed")


def check_template_files(repo: Path, report: Report) -> None:
    """TC005 (undeclared parameters used) and TC009 (secrets/xtrace) for every template/entry file."""
    paths = [repo / f for f in ENTRY_FILES if (repo / f).exists()]
    for d in TEMPLATE_DIRS:
        paths += sorted((repo / d).glob("*.yml"))
    paths += sorted((repo / "pipelines/generated").glob("*.yml"))
    for p in paths:
        rel = p.relative_to(repo).as_posix()
        text = p.read_text()
        doc = load_yaml(p)
        declared = declared_params(doc)
        body = strip_comments(text)
        for m in PARAM_USE_RE.finditer(body):
            name = m.group(1) or m.group(2)
            if name not in declared:
                report.add("TC005", rel, f"uses parameters.{name} which it does not declare")
        for m in XTRACE_RE.finditer(body):
            report.add("TC009", rel, f"enables xtrace: {m.group(0).strip()}")
        for line in body.splitlines():
            if SECRET_ECHO_RE.search(line):
                report.add("TC009", rel, f"echoes a secret: {line.strip()}")
    for p in sorted((repo / "pipelines/scripts").glob("*.sh")):
        text = p.read_text()
        rel = p.relative_to(repo).as_posix()
        for m in XTRACE_RE.finditer(strip_comments(text)):
            report.add("TC009", rel, f"enables xtrace: {m.group(0).strip()}")
        for line in strip_comments(text).splitlines():
            if SECRET_ECHO_RE.search(line):
                report.add("TC009", rel, f"echoes a secret: {line.strip()}")


def check_settings_keys(repo: Path, report: Report) -> None:
    universal = repo / "pipelines/templates/universal-stages.yml"
    if not universal.exists():
        return
    provided = set()
    for ref, _ in iter_template_refs(load_yaml(universal)):
        s = (ref.get("parameters") or {}).get("settings")
        if isinstance(s, dict):
            provided |= set(s)
    for p in sorted((repo / "pipelines/templates").glob("*.yml")):
        for key in set(SETTINGS_USE_RE.findall(strip_comments(p.read_text()))):
            if key not in provided:
                report.add("TC006", p.relative_to(repo).as_posix(), f"uses parameters.settings.{key}, which universal-stages.yml never provides")


# ----------------------------------------------------- expanded structure
def _jobs_of(repo: Path, stage: dict, stage_file: Path) -> List[Tuple[str, List[str]]]:
    """(job name, dependsOn) of a stage; template job names substituted from passed parameters."""
    out = []

    def collect(items, file: Path, params: dict):
        for item in items or []:
            if not isinstance(item, dict):
                continue
            if "template" in item:
                target = resolve_ref(repo, file, item["template"])
                if target and target.exists():
                    tdoc = load_yaml(target)
                    collect(tdoc.get("jobs"), target, item.get("parameters") or {})
                continue
            for k, v in item.items():
                if isinstance(k, str) and k.startswith("${{"):
                    collect(v, file, params)
            name = item.get("job") or item.get("deployment")
            if name is None:
                continue
            m = re.fullmatch(r"\$\{\{\s*parameters\.([A-Za-z_]+)\s*\}\}", str(name))
            if m:
                name = params.get(m.group(1), name)
            deps = item.get("dependsOn") or []
            out.append((str(name), [deps] if isinstance(deps, str) else list(deps)))

    collect(stage.get("jobs"), stage_file, {})
    return out


def expanded_stages(repo: Path, scope: str = "platform") -> List[Tuple[dict, Path]]:
    """Stages of one pipeline scope after expanding stage templates (PR and CI branches; the tag-only
    release branch is checked separately)."""
    entry = repo / "pipelines/templates/universal-stages.yml"
    result = []

    def collect(items, file: Path, params: dict):
        for item in items or []:
            if not isinstance(item, dict):
                continue
            for k, v in item.items():
                if isinstance(k, str) and k.startswith("${{"):
                    collect(v, file, params)
            if "template" in item:
                ref = item["template"].replace("${{ parameters.scope }}", scope)
                target = resolve_ref(repo, file, ref)
                if target and target.exists():
                    collect(load_yaml(target).get("stages"), target, item.get("parameters") or {})
            elif "stage" in item:
                st = dict(item)
                dep = st.get("dependsOn")
                if isinstance(dep, str) and dep.strip().startswith("${{"):
                    st["dependsOn"] = params.get("dependsOn", [])
                result.append((st, file))

    if entry.exists():
        collect(load_yaml(entry).get("stages"), entry, {})
    return result


def check_structure(repo: Path, report: Report) -> dict:
    metrics = {}
    max_jobs_all = 0
    for scope in ("platform", "applications"):
        stages = expanded_stages(repo, scope)
        names = [s["stage"] for s, _ in stages]
        seen = set()
        for n in names:
            if n in seen:
                report.add("TC007", f"{scope} pipeline", f"duplicate stage name '{n}'")
            seen.add(n)
        max_jobs = 0
        for st, f in stages:
            deps = st.get("dependsOn") or []
            deps = [deps] if isinstance(deps, str) else deps
            for d in deps:
                if d not in seen:
                    report.add("TC007", f"{scope} pipeline", f"stage '{st['stage']}' dependsOn unknown stage '{d}'")
            jobs = _jobs_of(repo, st, f)
            jn = [j for j, _ in jobs]
            for j in set(jn):
                if jn.count(j) > 1:
                    report.add("TC008", f"{scope} pipeline", f"stage '{st['stage']}' has duplicate job '{j}'")
            for j, jdeps in jobs:
                for d in jdeps:
                    if d not in jn:
                        report.add("TC008", f"{scope} pipeline", f"stage '{st['stage']}' job '{j}' dependsOn unknown job '{d}'")
            max_jobs = max(max_jobs, len(jobs))
        if len(names) > LIMITS["stages_warn"]:
            report.add("LIM005", f"{scope} pipeline", f"{len(names)} stages: split further (README 'Scaling')", "warning")
        metrics[scope] = {"stages": len(names), "max_jobs_per_stage": max_jobs}
        max_jobs_all = max(max_jobs_all, max_jobs)
    max_jobs = max_jobs_all
    # validate matrix legs: one per selected component (+ changed modules) - bounded by the registry size
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree

    try:
        legs = sum(1 for c in load_registry(WorkTree(repo)) if c.pipeline != "manual")
    except Exception:  # noqa: BLE001 - registry problems are reported by other linters
        legs = 0
    if max(max_jobs, legs) > LIMITS["jobs_per_stage"]:
        report.add("LIM004", "expanded pipeline", f"{max(max_jobs, legs)} jobs in one stage (ADO limit 256, budget "
                   f"{LIMITS['jobs_per_stage']}): split the Build stage / shard the validate matrix")
    metrics["validate_matrix_max_legs"] = legs
    return metrics


# --------------------------------------------------------------- environments
def _variables(repo: Path, env: str) -> dict:
    p = repo / f"pipelines/variables/{env}.yml"
    return (load_yaml(p) or {}).get("variables", {}) if p.exists() else {}


def _param_values(doc: dict, name: str) -> Tuple[list, object]:
    for p in (doc or {}).get("parameters", []) or []:
        if isinstance(p, dict) and p.get("name") == name:
            return list(p.get("values") or []), p.get("default")
    return [], None


def check_environments(repo: Path, report: Report) -> None:
    from tools.config.promotion import PromotionError, load

    try:
        envs = load(repo)
    except PromotionError as exc:
        report.add("ENV001", "environments/promotion.yaml", str(exc))
        return
    for name in envs:
        if not (repo / f"environments/{name}/environment.yaml").exists():
            report.add("ENV001", f"environments/{name}", "missing environment.yaml")
        if not (repo / f"pipelines/variables/{name}.yml").exists():
            report.add("ENV001", f"pipelines/variables/{name}.yml", "missing pipeline variables file")
    for d in sorted((repo / "environments").iterdir()):
        if (d / "environment.yaml").exists() and d.name not in envs:
            report.add("ENV001", f"environments/{d.name}", "environment is not part of any chain in environments/promotion.yaml")
    for f in sorted((repo / "pipelines/variables").glob("*.yml")):
        if f.stem not in envs and f.stem != "tools":
            report.add("ENV001", f.relative_to(repo).as_posix(), "variables file for an environment without a chain entry")
    ci = [e.name for e in envs.values() if e.ci_trigger]
    for entry, scope in ENTRY_SCOPES.items():
        if not (repo / entry).exists():
            report.add("ENT001", entry, "entry pipeline missing")
            continue
        doc = load_yaml(repo / entry) or {}
        values, default = _param_values(doc, "environment")
        if sorted(values) != sorted(envs):
            report.add("ENV002", entry, f"environment values {values} != promotion environments {sorted(envs)}")
        if ci and default not in ci:
            report.add("ENV002", entry, f"default environment {default!r} must be the ci_trigger environment {ci}")
        modes, _ = _param_values(doc, "mode")
        allowed = sorted({m for e in envs.values() for m in e.allowed_modes})
        if sorted(modes) != allowed:
            report.add("ENV002", entry, f"mode values {sorted(modes)} != modes allowed by environments/promotion.yaml {allowed}")
        ext = (doc.get("extends") or {})
        if not str(ext.get("template", "")).endswith("pipelines/templates/universal.yml"):
            report.add("ENT002", entry, "must extend pipelines/templates/universal.yml (Required template check)")
        elif (ext.get("parameters") or {}).get("scope") != scope:
            report.add("ENT002", entry, f"must pass scope: {scope}")
        if set(doc) - {"name", "trigger", "pr", "schedules", "resources", "lockBehavior", "parameters", "extends",
                        "appendCommitMessageToRunName"}:
            report.add("ENT002", entry, f"thin entry may not define {sorted(set(doc) - {'name', 'trigger', 'pr', 'schedules', 'resources', 'lockBehavior', 'parameters', 'extends', 'appendCommitMessageToRunName'})}")
    apps = load_yaml(repo / "azure-pipelines.applications.yml") if (repo / "azure-pipelines.applications.yml").exists() else {}
    res = [p for p in ((apps or {}).get("resources") or {}).get("pipelines", []) if p.get("pipeline") == "platform"]
    if not res or not (res[0].get("trigger") or {}).get("branches"):
        report.add("ENT003", "azure-pipelines.applications.yml",
                   "needs resources.pipelines 'platform' with a trigger on main (re-plan consumers after platform runs)")
    plat = load_yaml(repo / "azure-pipelines.yml") if (repo / "azure-pipelines.yml").exists() else {}
    tags = (((plat or {}).get("trigger") or {}).get("tags") or {}).get("include") or []
    if "observability-v*" not in tags:
        report.add("ENT004", "azure-pipelines.yml", "must trigger on tags observability-v* (package release stage)")
    others = []
    for p in list(repo.glob("*.yml")) + list(repo.glob("*.yaml")) + list((repo / "pipelines").glob("*.yml")):
        rel = p.relative_to(repo).as_posix()
        if rel in ENTRY_FILES:
            continue
        doc = load_yaml(p)
        if isinstance(doc, dict) and ({"trigger", "extends", "pr", "schedules"} & set(doc) or
                                      ("stages" in doc and "parameters" not in doc)):
            others.append(rel)
    if others:
        report.add("ENT001", ", ".join(sorted(others)), "only two entry pipelines are allowed "
                   "(azure-pipelines.yml, azure-pipelines.applications.yml)")
    for name, spec in envs.items():
        v = _variables(repo, name)
        want = spec.promote_from or ""
        if str(v.get("promoteFrom", "")) != want:
            report.add("ENV003", f"pipelines/variables/{name}.yml", f"promoteFrom {v.get('promoteFrom')!r} != chain {want!r}")
        if spec.promote_from:
            src = _variables(repo, spec.promote_from)
            for mine, theirs in (("promoteFromStateStorageAccount", "stateStorageAccount"),
                                 ("promoteFromContainerRegistry", "containerRegistry")):
                if v.get(mine) != src.get(theirs):
                    report.add("ENV003", f"pipelines/variables/{name}.yml",
                               f"{mine} {v.get(mine)!r} != {spec.promote_from}'s {theirs} {src.get(theirs)!r}")
        else:
            for k in ("promoteFromStateStorageAccount", "promoteFromContainerRegistry"):
                if v.get(k):
                    report.add("ENV003", f"pipelines/variables/{name}.yml", f"{k} must be empty for a building environment")


# ------------------------------------------------------------------- driver
def run(repo: Path) -> Report:
    _cache.clear()
    repo = Path(repo).resolve()
    report = Report()
    walker = Walker(repo, report)
    for entry in ENTRY_FILES:
        p = repo / entry
        if not p.exists():
            continue
        m = walker.walk(p, ENTRY_SCOPES.get(entry))
        report.metrics[entry] = m
        if m["files"] > LIMITS["files"]:
            report.add("LIM001", entry, f"{m['files']} YAML files (ADO limit 100, budget {LIMITS['files']})")
        if m["depth"] > LIMITS["depth"]:
            report.add("LIM002", entry, f"template nesting depth {m['depth']} (ADO limit 100, budget {LIMITS['depth']})")
        if m["expanded_bytes"] > LIMITS["size_fail"]:
            report.add("LIM003", entry, f"estimated expanded size {m['expanded_bytes']:,} bytes > {LIMITS['size_fail']:,} "
                       "(ADO: 20 MB parse memory, typically 600 KB-2 MB on disk); see README 'Scaling'")
        elif m["expanded_bytes"] > LIMITS["size_warn"]:
            report.add("LIM003", entry, f"estimated expanded size {m['expanded_bytes']:,} bytes > {LIMITS['size_warn']:,} "
                       "(approaching the documented range)", "warning")
    check_template_files(repo, report)
    check_settings_keys(repo, report)
    report.metrics["structure"] = check_structure(repo, report)
    check_environments(repo, report)
    return report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    report = run(Path(args.repo))
    if args.json:
        print(json.dumps({"findings": [f.__dict__ for f in report.findings], "metrics": report.metrics}, indent=2))
    else:
        for f in report.findings:
            print(f)
        for entry, m in report.metrics.items():
            print(f"metrics {entry}: {m}")
        print(f"pipeline templates: {len(report.errors)} error(s), "
              f"{len(report.findings) - len(report.errors)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
