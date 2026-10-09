"""Dependency graph over the component registry.

Edge kinds (upstream -> component):
  hard       depends_on, producers of `consumes`, `artifacts`
  optional   producers of `optional_consumes` (only honoured when the producer is enabled);
             an entry listed in both consumes and optional_consumes is treated as optional
  after      implicit optional edges for `after_deployments: true` (every applications-layer root)
  discovers  implicit optional edges for `discovers_resources: true` (every platform/applications root)
"""

from __future__ import annotations

import posixpath
import re
from collections import defaultdict
from typing import Dict, Iterable, List, Optional, Set, Tuple

from .registry import Component, Registry
from .trees import Tree

MODULE_SOURCE_RE = re.compile(r'^\s*source\s*=\s*"(\.{1,2}/[^"]*)"', re.MULTILINE)


class CycleError(Exception):
    def __init__(self, cycle: List[str]):
        self.cycle = cycle
        super().__init__("dependency cycle: " + " -> ".join(cycle))


def discover_modules(tree: Tree, root_dir: str) -> List[str]:
    """Local module directories referenced (recursively) from the .tf files of `root_dir`."""
    found: Set[str] = set()
    pending = [root_dir.rstrip("/")]
    visited: Set[str] = set()
    while pending:
        d = pending.pop()
        if d in visited:
            continue
        visited.add(d)
        prefix = d + "/"
        for path in tree.files():
            if not path.startswith(prefix) or "/" in path[len(prefix):]:
                continue
            if not path.endswith(".tf"):
                continue
            text = tree.read_text(path) or ""
            for src in MODULE_SOURCE_RE.findall(text):
                target = posixpath.normpath(posixpath.join(d, src.split("//")[0]))
                if target.startswith("..") or target == ".":
                    continue
                if target == root_dir or target.startswith(root_dir.rstrip("/") + "/"):
                    # module inside the component itself: still recurse, not a shared dependency
                    pending.append(target)
                    continue
                if target not in found:
                    found.add(target)
                    pending.append(target)
    return sorted(found)


class Graph:
    def __init__(self, registry: Registry):
        self.registry = registry
        self._reverse: Optional[Dict[str, Dict[str, str]]] = None
        self.edges: Dict[str, Dict[str, str]] = defaultdict(dict)  # comp -> {upstream: kind}
        for c in registry:
            optional = {registry.producer_of(e) for e in c.optional_consumes}
            for dep in c.depends_on:
                self.edges[c.id][dep] = "hard"
            for e in c.consumes:
                p = registry.producer_of(e)
                if p and p != c.id and p not in optional:
                    self.edges[c.id][p] = "hard"
            for a in c.artifacts:
                self.edges[c.id][a] = "artifact"
            for p in optional:
                if p and p != c.id:
                    self.edges[c.id].setdefault(p, "optional")
        # implicit edges must never create cycles: skip anything already downstream
        for c in registry:
            if not (c.after_deployments or c.discovers_resources):
                continue
            downstream = self.transitive_consumers([c.id], include_implicit=False)
            for other in registry:
                if other.id == c.id or other.id in downstream or not other.deployable:
                    continue
                if other.after_deployments or other.discovers_resources:
                    continue
                if c.after_deployments and other.layer == "applications":
                    self.edges[c.id].setdefault(other.id, "after")
                if c.discovers_resources and other.layer in ("platform", "applications"):
                    self.edges[c.id].setdefault(other.id, "discovers")
        self._reverse = None

    # ------------------------------------------------------------------ queries
    def reverse(self) -> Dict[str, Dict[str, str]]:
        if self._reverse is None:
            rev: Dict[str, Dict[str, str]] = defaultdict(dict)
            for c, ups in self.edges.items():
                for u, kind in ups.items():
                    rev[u][c] = kind
            self._reverse = rev
        return self._reverse

    def upstream(self, cid: str, enabled: Optional[Set[str]] = None, kinds: Optional[Iterable[str]] = None) -> Dict[str, str]:
        """Direct upstream {id: kind}. Optional-type edges are dropped when the producer is not enabled."""
        result = {}
        for u, kind in self.edges.get(cid, {}).items():
            if kinds is not None and kind not in kinds:
                continue
            if enabled is not None and kind in ("optional", "after", "discovers") and u not in enabled:
                continue
            result[u] = kind
        return result

    def hard_upstream(self, cid: str) -> Dict[str, str]:
        return self.upstream(cid, kinds=("hard", "artifact"))

    def transitive_upstream(self, cid: str, enabled: Optional[Set[str]] = None, kinds=None) -> Set[str]:
        seen: Set[str] = set()
        stack = [cid]
        while stack:
            cur = stack.pop()
            for u in self.upstream(cur, enabled, kinds):
                if u not in seen:
                    seen.add(u)
                    stack.append(u)
        return seen

    def consumers(self, cid: str, include_implicit: bool = True) -> Dict[str, str]:
        res = self.reverse().get(cid, {})
        if include_implicit:
            return dict(res)
        return {k: v for k, v in res.items() if v not in ("after", "discovers")}

    def transitive_consumers(self, ids: Iterable[str], enabled: Optional[Set[str]] = None, include_implicit: bool = True) -> Set[str]:
        if not include_implicit and self._reverse is None:
            # called during construction: compute from explicit edges only
            rev: Dict[str, Set[str]] = defaultdict(set)
            for c, ups in self.edges.items():
                for u, kind in ups.items():
                    if kind not in ("after", "discovers"):
                        rev[u].add(c)
            seen: Set[str] = set()
            stack = list(ids)
            while stack:
                cur = stack.pop()
                for d in rev.get(cur, ()):
                    if d not in seen:
                        seen.add(d)
                        stack.append(d)
            return seen
        seen = set()
        stack = list(ids)
        while stack:
            cur = stack.pop()
            for d, kind in self.consumers(cur, include_implicit).items():
                if enabled is not None and d not in enabled:
                    continue
                if enabled is not None and kind in ("optional", "after", "discovers") and cur not in enabled:
                    continue
                if d not in seen:
                    seen.add(d)
                    stack.append(d)
        return seen

    # --------------------------------------------------------------- structure
    def find_cycle(self) -> Optional[List[str]]:
        WHITE, GREY, BLACK = 0, 1, 2
        color = {c.id: WHITE for c in self.registry}
        stack: List[str] = []

        def visit(n: str) -> Optional[List[str]]:
            color[n] = GREY
            stack.append(n)
            for u in sorted(self.edges.get(n, {})):
                if color.get(u, BLACK) == GREY:
                    i = stack.index(u)
                    # report in dependency order: upstream -> ... -> consumer -> upstream
                    cyc = stack[i:] + [u]
                    return list(reversed(cyc))
                if color.get(u) == WHITE:
                    r = visit(u)
                    if r:
                        return r
            stack.pop()
            color[n] = BLACK
            return None

        for cid in sorted(color):
            if color[cid] == WHITE:
                r = visit(cid)
                if r:
                    return r
        return None

    def check_acyclic(self) -> None:
        cyc = self.find_cycle()
        if cyc:
            raise CycleError(cyc)

    def layers(self, nodes: Optional[Iterable[str]] = None, enabled: Optional[Set[str]] = None) -> List[List[str]]:
        """Topological layers (longest path from a source) restricted to `nodes`."""
        self.check_acyclic()
        node_set = set(nodes) if nodes is not None else {c.id for c in self.registry}
        depth: Dict[str, int] = {}

        def d(n: str, trail: Tuple[str, ...] = ()) -> int:
            if n in depth:
                return depth[n]
            ups = [u for u in self.transitive_upstream_direct(n, enabled) if u in node_set]
            val = 0 if not ups else 1 + max(d(u) for u in ups)
            depth[n] = val
            return val

        for n in node_set:
            d(n)
        out: List[List[str]] = []
        for n, k in depth.items():
            while len(out) <= k:
                out.append([])
            out[k].append(n)
        return [sorted(x) for x in out if x]

    def transitive_upstream_direct(self, n: str, enabled: Optional[Set[str]]) -> List[str]:
        """Upstream nodes used for layering: direct edges, but skipping through nodes not in scope
        is handled by callers that pass the full transitive set."""
        return list(self.transitive_upstream(n, enabled))

    def layer_index(self, enabled: Optional[Set[str]] = None) -> Dict[str, int]:
        idx = {}
        for i, layer in enumerate(self.layers(enabled=enabled)):
            for n in layer:
                idx[n] = i
        return idx


def components_owning(registry: Registry, path: str) -> List[Component]:
    """Most specific component whose `path` contains the file (nested component paths win)."""
    best: Optional[Component] = None
    for c in registry:
        if path == c.path or path.startswith(c.path + "/"):
            if best is None or len(c.path) > len(best.path):
                best = c
    return [best] if best else []
