"""Component fingerprints.

deploy_fp      sha256 over the parts that can change what is deployed:
                 source     files under the component path + discovered shared module dirs + `inputs`
                            globs, EXCLUDING docs/README/*.md and tests
                 config     rendered tfvars (tools/config render) for that component only
                 tools      versions.yaml sections relevant to the component kind
                 artifacts  deploy roots: source fingerprints (or supplied digests) of their artifacts
                 contracts  major versions of the upstream contracts it consumes
                 registry   the component's own registry entry
validation_fp  same, but the source part includes tests and docs (anything that needs re-validation)

Part hashes are kept (`parts`) so selection can tell an artifact-only change (no downstream contract
impact) from an infrastructure change (consumers must be re-planned).
"""

from __future__ import annotations

import hashlib
import json
import posixpath
import re
from typing import Dict, List, Optional, Set

import yaml

from . import globs
from .graph import Graph, discover_modules
from .registry import Component, Registry
from .trees import Tree

TEST_DIR_NAMES = {"tests", "test", "__tests__", "testdata"}
TEST_DIR_SUFFIXES = (".Tests", ".UnitTests", ".IntegrationTests", ".Test")
DOC_DIR_NAMES = {"docs"}
CONTRACT_SCHEMA_RE = re.compile(r"^catalog/contracts/(?P<name>[a-z0-9-]+)\.v(?P<major>\d+)\.schema\.json$")


def is_doc(path: str) -> bool:
    name = posixpath.basename(path)
    lower = name.lower()
    if lower.endswith((".md", ".markdown", ".adoc", ".rst")):
        return True
    if lower.startswith(("readme", "changelog", "license")):
        return True
    return any(p in DOC_DIR_NAMES for p in path.split("/")[:-1])


def is_test(path: str) -> bool:
    parts = path.split("/")
    name = parts[-1]
    if any(p in TEST_DIR_NAMES or p.endswith(TEST_DIR_SUFFIXES) for p in parts[:-1]):
        return True
    if name.endswith(".tftest.hcl") or name.endswith(".tftest.json"):
        return True
    if re.match(r"^(test_.*|.*_test)\.py$", name) or re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", name):
        return True
    return name in ("conftest.py", "pytest.ini", ".coveragerc")


def deploy_relevant(path: str) -> bool:
    return not is_doc(path) and not is_test(path)


def sha256_json(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def contract_majors(tree: Tree) -> Dict[str, int]:
    majors: Dict[str, int] = {}
    for path in tree.files():
        m = CONTRACT_SCHEMA_RE.match(path)
        if m:
            majors[m["name"]] = max(majors.get(m["name"], 0), int(m["major"]))
    return majors


class Fingerprinter:
    def __init__(self, tree: Tree, registry: Registry, graph: Graph, env: str,
                 env_doc: Optional[dict], profile_doc: Optional[dict], enabled: Optional[Set[str]],
                 artifact_digests: Optional[Dict[str, str]] = None):
        self.tree = tree
        self.registry = registry
        self.graph = graph
        self.env = env
        self.env_doc = env_doc or {}
        self.profile_doc = profile_doc or {}
        self.enabled = enabled
        self.artifact_digests = artifact_digests or {}
        self._modules: Dict[str, List[str]] = {}
        self._files: Dict[str, Dict[str, str]] = {}
        self._parts: Dict[str, Dict[str, str]] = {}
        self._vparts: Dict[str, Dict[str, str]] = {}
        self._versions: Optional[dict] = None
        self._majors: Optional[Dict[str, int]] = None
        self._nested: Dict[str, List[str]] = {}

    # ------------------------------------------------------------- file sets
    def modules(self, cid: str) -> List[str]:
        if cid not in self._modules:
            c = self.registry.get(cid)
            self._modules[cid] = discover_modules(self.tree, c.path) if c.is_terraform else []
        return self._modules[cid]

    def _nested_paths(self, c: Component) -> List[str]:
        if c.id not in self._nested:
            self._nested[c.id] = [o.path for o in self.registry if o.id != c.id and o.path.startswith(c.path + "/")]
        return self._nested[c.id]

    def owns(self, c: Component, path: str) -> bool:
        """True when `path` is an input of component `c` (path, shared modules, inputs globs)."""
        if c.is_docs:
            return globs.under(path, c.path) or (bool(c.inputs) and globs.match_any(c.inputs, path))
        if globs.under(path, c.path) and not any(globs.under(path, n) for n in self._nested_paths(c)):
            return True
        if any(globs.under(path, m) for m in self.modules(c.id)):
            return True
        if c.inputs and globs.match_any(c.inputs, path):
            return True
        for contract in c.produces:
            m = CONTRACT_SCHEMA_RE.match(path)
            if m and m["name"] == contract:
                return True
        return False

    def files(self, cid: str) -> Dict[str, str]:
        if cid not in self._files:
            c = self.registry.get(cid)
            self._files[cid] = {p: b for p, b in self.tree.files().items() if self.owns(c, p)}
        return self._files[cid]

    # ----------------------------------------------------------------- parts
    def versions(self) -> dict:
        if self._versions is None:
            text = self.tree.read_text("versions.yaml")
            self._versions = (yaml.safe_load(text) or {}) if text else {}
        return self._versions

    def majors(self) -> Dict[str, int]:
        if self._majors is None:
            self._majors = contract_majors(self.tree)
        return self._majors

    def tool_versions(self, c: Component) -> dict:
        v = self.versions()
        if c.is_terraform:
            out = {"terraform": v.get("terraform")}
            if c.layer == "observability":
                out["images"] = v.get("images")
            return out
        if c.is_artifact:
            return {"runtimes": v.get("runtimes")}
        return {}

    def consumed_contracts(self, c: Component) -> Dict[str, str]:
        """{contract: 'vN'} for hard consumes + optional consumes whose producer is enabled."""
        out = {}
        optional = set(c.optional_consumes)
        for entry in list(c.consumes) + list(c.optional_consumes):
            producer = self.registry.producer_of(entry)
            if entry in optional and self.enabled is not None and producer not in self.enabled:
                continue
            out[entry] = f"v{self.majors().get(entry, 0)}"
        return out

    def config(self, c: Component) -> Optional[dict]:
        if not c.is_terraform or not self.env_doc:
            return None
        from tools.config.lib import render_component  # local import: avoids a cycle

        return render_component(self.tree, self.registry, self.env_doc, self.profile_doc, c.id)

    def _source_hash(self, cid: str, deploy: bool) -> str:
        items = sorted((p, b) for p, b in self.files(cid).items() if (deploy_relevant(p) or not deploy))
        h = hashlib.sha256()
        for p, b in items:
            h.update(f"{p}\0{b}\n".encode())
        return h.hexdigest()

    def parts(self, cid: str) -> Dict[str, str]:
        if cid not in self._parts:
            c = self.registry.get(cid)
            parts = {
                "source": self._source_hash(cid, deploy=True),
                "config": sha256_json(self.config(c)),
                "tools": sha256_json(self.tool_versions(c)),
                "contracts": sha256_json(self.consumed_contracts(c)),
                "registry": sha256_json(c.raw),
            }
            if c.artifacts:
                arts = {}
                for a in c.artifacts:
                    arts[a] = self.artifact_digests.get(a) or ("src:" + self.deploy_fp(a))
                parts["artifacts"] = sha256_json(arts)
            self._parts[cid] = parts
        return self._parts[cid]

    def deploy_fp(self, cid: str) -> str:
        return sha256_json(self.parts(cid))

    def validation_parts(self, cid: str) -> Dict[str, str]:
        if cid not in self._vparts:
            p = dict(self.parts(cid))
            p["source"] = self._source_hash(cid, deploy=False)
            p.pop("artifacts", None)  # artifact digests do not change what must be validated
            self._vparts[cid] = p
        return self._vparts[cid]

    def validation_fp(self, cid: str) -> str:
        return sha256_json(self.validation_parts(cid))


def changed_parts(old: Optional[Dict[str, str]], new: Dict[str, str]) -> List[str]:
    if not old:
        return sorted(new)
    return sorted(k for k in set(old) | set(new) if old.get(k) != new.get(k))
