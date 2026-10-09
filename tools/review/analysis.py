"""Change analysis: changed files -> change classes, components (tools/changeset registry, read-only), layers,
affected consumers, dependency bumps and observability refinements.

Component attribution reuses tools.changeset (registry loading, Graph, Fingerprinter.owns) on the TRUSTED base
tree. With a full git tree (local runs) shared-module discovery is exact; in the Function only the registry files
are fetched, so paths under shared module directories are classified by path (they are never auto-approvable).
"""

from __future__ import annotations

import posixpath
import re

from tools.changeset import globs
from tools.changeset.fingerprint import Fingerprinter, is_doc, is_test
from tools.changeset.graph import Graph
from tools.changeset.registry import Registry, RegistryError, load_registry
from tools.changeset.trees import Tree

from . import deps, observability
from .model import FileChange, Finding
from .policy import Policy

DOC_EXTENSIONS = (".md", ".markdown", ".adoc", ".rst", ".txt", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".mmd", ".drawio")
SHARED_MODULE_RE = re.compile(r"^((?:[^/]+/)*modules/[^/]+)/")
NPM_REGISTRY = "https://registry.npmjs.org/"


class MappingTree(Tree):
    """A Tree over a handful of trusted files fetched from the target branch (Function mode)."""

    def __init__(self, files: dict[str, bytes], label: str = "mapping"):
        from tools.changeset.trees import git_blob_id

        self._data = dict(files)
        self._ids = {p: git_blob_id(b) for p, b in self._data.items()}
        self.label = label

    def files(self) -> dict[str, str]:
        return self._ids

    def read_bytes(self, path: str) -> bytes | None:
        return self._data.get(path)


class TrustedBase:
    """Registry + graph + ownership from the trusted (target branch) tree."""

    def __init__(self, tree: Tree):
        self.tree = tree
        self.notes: list[str] = []
        self.registry: Registry | None = None
        self.graph: Graph | None = None
        self.fp: Fingerprinter | None = None
        try:
            self.registry = load_registry(tree)
            self.graph = Graph(self.registry)
            self.fp = Fingerprinter(tree, self.registry, self.graph, "review", None, None, None)
        except (RegistryError, Exception) as exc:
            self.notes.append(f"component registry unavailable at base ({exc.__class__.__name__}); no component attribution")

    def read_text(self, path: str) -> str | None:
        return self.tree.read_text(path) if path else None

    def owners_of(self, path: str) -> list[str]:
        if not self.registry or not self.fp:
            return []
        return [c.id for c in self.registry if self.fp.owns(c, path)]


def builtin_match(kind: str, path: str) -> bool:
    if kind == "docs":
        name = posixpath.basename(path).lower()
        return is_doc(path) and (name.endswith(DOC_EXTENSIONS) or name.startswith(("readme", "changelog", "license")))
    if kind == "tests":
        return is_test(path)
    return False


def base_class(policy: Policy, path: str) -> tuple[str, str | None]:
    for c in policy.classes:
        if c.get("globs") and globs.match_any(c["globs"], path):
            return c["name"], c.get("refine")
        if c.get("builtin") and builtin_match(c["builtin"], path):
            return c["name"], c.get("refine")
    return "code", None


def refine_dependencies(policy: Policy, ch: FileChange, added_lines: list[tuple[int, str]]) -> tuple[str, list[Finding], list[dict]]:
    findings: list[Finding] = []
    changes = deps.classify(ch.path, ch.base_text, ch.head_text)
    if changes is None or ch.head_text is None or ch.base_text is None:
        return "dependency-change", findings, []
    bumps = [{"package": p, "kind": k, "old": o, "new": n} for p, k, o, n in changes]
    ok = all(b["kind"] in ("patch", "same") or (b["kind"] == "added" and policy["dependencies"]["allow_new_packages"]) for b in bumps)
    name = posixpath.basename(ch.path)
    if name.startswith("requirements"):
        for ln, line in added_lines:
            s = line.strip()
            if s and not s.startswith("#") and not deps.PEP440.match(line):
                ok = False
                findings.append(
                    Finding(
                        rule="dependency.non-pin-line",
                        severity="medium",
                        kind="risk",
                        category="dependency",
                        message="Requirements file gained a non-pin line (index URL / option / VCS reference).",
                        file=ch.path,
                        line=ln,
                        evidence=f"nonpin:{s[:80]}",
                        suggestion="Only exact `name==version` pins belong in compiled requirements files.",
                    )
                )
    if name == "package-lock.json":
        for ln, line in added_lines:
            m = re.search(r'"resolved"\s*:\s*"([^"]+)"', line)
            if m and not m.group(1).startswith(NPM_REGISTRY):
                ok = False
                findings.append(
                    Finding(
                        rule="dependency.registry",
                        severity="high",
                        kind="risk",
                        category="dependency",
                        message="Lockfile resolves a package from outside registry.npmjs.org.",
                        file=ch.path,
                        line=ln,
                        evidence=f"resolved:{m.group(1)[:80]}",
                    )
                )
    for b in bumps:
        if b["kind"] in ("major", "downgrade"):
            findings.append(
                Finding(
                    rule=f"dependency.{b['kind']}",
                    severity="low",
                    kind="quality",
                    category="dependency",
                    message=f"{b['package']}: {b['old']} -> {b['new']} ({b['kind']} change) - check release notes.",
                    file=ch.path,
                    evidence=f"{b['kind']}:{b['package']}:{b['new']}",
                )
            )
    return ("dependency-patch" if ok and bumps else "dependency-change"), findings, bumps


def classify(policy: Policy, base: TrustedBase, ch: FileChange, added: list[tuple[int, str]]) -> tuple[str, list[Finding], dict]:
    """Final class of one change (a rename takes the stricter of old/new path classes)."""
    findings: list[Finding] = []
    extra: dict = {}
    names = []
    for p in ch.paths:
        name, refine = base_class(policy, p)
        if refine == "dependencies":
            name, f, bumps = refine_dependencies(policy, ch, added)
            findings += f
            extra["bumps"] = bumps
        elif refine == "observability":
            name, f = observability.refine(p, ch.base_text if p == (ch.old_path or ch.path) else None, ch.head_text, policy["observability"], base.read_text)
            findings += f
        names.append(name)
    if len(set(names)) > 1:
        approvable = set(policy["decision"]["auto_approve_classes"])
        never = [n for n in names if policy.never_approve(n)]
        name = never[0] if never else next((n for n in names if n not in approvable), names[-1])
    else:
        name = names[0]
    if (ch.binary or ch.too_large) and name not in ("docs",):
        findings.append(
            Finding(
                rule="change.binary-or-large",
                severity="medium",
                kind="quality",
                category="size",
                message="Binary or very large file: the reviewer cannot inspect its content.",
                file=ch.path,
                evidence="binary" if ch.binary else "too-large",
            )
        )
    shared = SHARED_MODULE_RE.match(ch.path)
    if shared:
        extra["shared_module"] = shared.group(1)
    return name, findings, extra
