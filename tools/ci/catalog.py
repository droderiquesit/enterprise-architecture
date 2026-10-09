"""Suite catalog: tools/ci/suites.yaml + one generated suite per registry component / changed shared module.

Suite ids:  <suite id from suites.yaml>   e.g. py-tools, obs-content, e2e
            component:<registry id>       tools/validate/component.py (terraform root: fmt/init/validate/test;
                                          artifact: unit tests by toolchain; docs: links)
            module:<dir>                  shared Terraform module (tools/validate/terraform.sh)
"""

from __future__ import annotations

import hashlib
import json
import posixpath
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

import yaml

from tools.changeset import globs
from tools.changeset.registry import Registry
from tools.changeset.trees import Tree

SUITES_FILE = "tools/ci/suites.yaml"
TIERS = ("gate", "unit", "integration", "e2e")
KINDS = ("pytest", "script", "dotnet", "component", "module")
TOOLCHAINS = ("python", "terraform", "dotnet", "node", "helm", "docker")
SUITE_KEYS = {"id", "tier", "kind", "scope", "toolchain", "paths", "argv", "projects", "inputs", "covers", "needs_env",
              "cache", "timeout_minutes"}


@dataclass
class Suite:
    id: str
    tier: str = "unit"
    kind: str = "pytest"
    scope: str = "platform"
    toolchain: str = "python"
    paths: List[str] = field(default_factory=list)
    argv: List[str] = field(default_factory=list)
    projects: List[str] = field(default_factory=list)
    inputs: List[str] = field(default_factory=list)
    covers: List[str] = field(default_factory=list)
    needs_env: Dict[str, str] = field(default_factory=dict)
    cache: bool = True
    timeout_minutes: int = 20
    component: Optional[str] = None      # generated component suites
    fingerprint: str = ""                # filled by fingerprint()

    @property
    def shardable(self) -> bool:
        return self.kind == "pytest"

    def to_json(self) -> dict:
        d = {k: v for k, v in self.__dict__.items() if v not in (None, [], {}, "")}
        d["shardable"] = self.shardable
        return d


@dataclass
class Catalog:
    suites: Dict[str, Suite]
    global_inputs: List[str]
    defaults: dict

    def get(self, sid: str) -> Suite:
        return self.suites[sid]


class CatalogError(ValueError):
    pass


def _toolchain_of_component(c) -> str:
    if c.is_terraform:
        return "terraform"
    if c.is_docs:
        return "python"
    p = c.path
    if c.raw.get("artifact", {}).get("type") == "static-bundle" or p.endswith("frontend"):
        return "node"
    if any(i.startswith("applications/shared/dotnet") for i in c.inputs) or p.endswith(("bff", "orders-api", "inventory-api", "durable")):
        return "dotnet"
    return "python"


def load(tree: Tree, registry: Registry) -> Catalog:
    text = tree.read_text(SUITES_FILE)
    if text is None:
        raise CatalogError(f"{SUITES_FILE} missing")
    doc = yaml.safe_load(text) or {}
    errors = validate_doc(doc)
    if errors:
        raise CatalogError("; ".join(errors))
    defaults = doc.get("defaults") or {}
    suites: Dict[str, Suite] = {}
    for raw in doc.get("suites") or []:
        s = Suite(**{k: v for k, v in raw.items() if k in SUITE_KEYS})
        if "timeout_minutes" not in raw:
            s.timeout_minutes = int(defaults.get("timeout_minutes", 20))
        suites[s.id] = s
    for c in registry:
        if c.pipeline == "manual":
            continue
        suites[f"component:{c.id}"] = Suite(
            id=f"component:{c.id}", tier="unit", kind="component", scope=c.scope if not c.is_docs else "platform",
            toolchain=_toolchain_of_component(c), component=c.id, timeout_minutes=int(c.raw.get("timeout_minutes", 60) or 60))
    return Catalog(suites=suites, global_inputs=list(doc.get("global_inputs") or []), defaults=defaults)


def module_suite(directory: str) -> Suite:
    return Suite(id=f"module:{directory}", tier="unit", kind="module", scope="platform", toolchain="terraform",
                 inputs=[f"{directory}/**"])


def validate_doc(doc: dict) -> List[str]:
    errors = []
    ids = [s.get("id") for s in doc.get("suites") or []]
    if ids != sorted(ids):
        errors.append("suites must be sorted by id")
    if len(set(ids)) != len(ids):
        errors.append("duplicate suite ids")
    for s in doc.get("suites") or []:
        sid = s.get("id", "?")
        unknown = set(s) - SUITE_KEYS
        if unknown:
            errors.append(f"{sid}: unknown keys {sorted(unknown)}")
        if s.get("tier") not in TIERS:
            errors.append(f"{sid}: tier must be one of {TIERS}")
        if s.get("kind") not in ("pytest", "script", "dotnet"):
            errors.append(f"{sid}: kind must be pytest | script | dotnet")
        if s.get("scope") not in ("platform", "applications"):
            errors.append(f"{sid}: scope must be platform | applications")
        if s.get("toolchain") not in TOOLCHAINS:
            errors.append(f"{sid}: toolchain must be one of {TOOLCHAINS}")
        if not s.get("inputs"):
            errors.append(f"{sid}: inputs required (selection + fingerprint)")
        if s.get("kind") == "pytest" and not s.get("paths"):
            errors.append(f"{sid}: pytest suites need paths")
        if s.get("kind") == "script" and not s.get("argv"):
            errors.append(f"{sid}: script suites need argv")
        if s.get("kind") == "dotnet" and not s.get("projects"):
            errors.append(f"{sid}: dotnet suites need projects")
    return errors


# ------------------------------------------------------------------ fingerprints
def _sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def matching_files(tree: Tree, patterns: List[str]) -> Dict[str, str]:
    if "**" in patterns:
        return dict(tree.files())
    return {p: b for p, b in tree.files().items() if globs.match_any(patterns, p)}


def tool_versions(tree: Tree, toolchain: str) -> dict:
    v = yaml.safe_load(tree.read_text("versions.yaml") or "") or {}
    out = {"runtimes": v.get("runtimes")}
    if toolchain in ("terraform",):
        out["terraform"] = v.get("terraform")
    return out


def fingerprint(suite: Suite, tree: Tree, catalog: Catalog, fp_component=None) -> str:
    """Test-result cache key. component suites reuse the changeset validation fingerprint (sources incl. tests,
    shared modules, rendered config, tool versions, consumed contract majors); others hash their input files."""
    parts = {"suite": suite.to_json(), "global": sorted(matching_files(tree, catalog.global_inputs).items())}
    if suite.kind == "component" and fp_component is not None:
        parts["component"] = fp_component(suite.component)
    else:
        parts["inputs"] = sorted(matching_files(tree, suite.inputs).items())
        parts["tools"] = tool_versions(tree, suite.toolchain)
    parts["suite"].pop("fingerprint", None)
    return _sha(parts)


def pytest_files(repo: Path, suite: Suite) -> List[str]:
    """Test files of a pytest suite (the sharding unit: xdist --dist loadfile keeps module fixtures together)."""
    out = []
    for p in suite.paths:
        base = repo / p
        if base.is_file():
            out.append(p)
            continue
        for f in sorted(base.rglob("test_*.py")):
            rel = f.relative_to(repo).as_posix()
            if "/__pycache__/" in rel or "/node_modules/" in rel or "/." in "/" + posixpath.dirname(rel):
                continue
            out.append(rel)
    return out
