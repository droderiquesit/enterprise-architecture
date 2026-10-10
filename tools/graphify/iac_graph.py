#!/usr/bin/env python3
"""Infrastructure-as-code layer for the Graphify knowledge graph (docs/guides/graphify.md).

Graphify's own AST pass (graphify-out/graph.json; Terraform needs the `graphifyy[terraform]` extra) models each .tf
file's blocks and references. It cannot know the architecture this repository encodes in YAML: the component
registry, contracts, artifacts, pipeline templates, Helm charts and deployment profiles. This adapter emits that
layer as a graphify-compatible graph (same node/link schema as graph.json) and can merge it into graph.json in place:

    python3 tools/graphify/iac_graph.py --out graphify-out/iac-graph.json
    python3 tools/graphify/iac_graph.py --out graphify-out/iac-graph.json --merge-into graphify-out/graph.json

Nodes (every id starts with `iac_`, so they never collide with graphify AST ids):
    iac_component_<id>        catalog/components.yaml entry (Terraform root, artifact build or docs)
    iac_tfmodule_<path>       directory with .tf files that is not a component (shared/local module)
    iac_tfmodule_ext_<src>    registry / git module source
    iac_tfresource_<type>     Terraform resource type        iac_tfdata_<type>  data source type
    iac_tfprovider_<source>   required provider (hashicorp/azurerm, ...)
    iac_contract_<name>       contract (catalog/contracts/<name>.v<N>.schema.json)
    iac_artifact_<component>  build output of an artifact component (image / package / bundle)
    iac_service_<id>          catalog/services entry referenced by a component (catalog_refs)
    iac_pipeline_<path>       Azure Pipelines file (pipelines/**/*.yml, azure-pipelines*.yml)
    iac_helmchart_<name>      applications/charts/<name>
    iac_profile_<name>        environments/profiles/<name>.yaml   iac_environment_<env>  environments/<env>
Relations: uses_module, consumes (context optional for optional_consumes), depends_on, produces_contract,
consumes_contract, builds, consumes_artifact, declares_resource (context resource|data, weight = block count),
requires_provider, implements_service, uses_template, runs_component, deploys_chart, enables, uses_profile, and
(with a base graph) implemented_by -> graphify's own `Terraform module: <dir>` node and has_schema -> the AST node
of each contract schema file.

Merging replaces every `iac_*` node and every link touching one, so it is idempotent and safe after
`graphify update .` (which keeps non-AST nodes). Stdlib + PyYAML only.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional, Tuple

import yaml

REPO = Path(__file__).resolve().parents[2]
ORIGIN = "iac"
PREFIX = "iac_"
SKIP_DIRS = {".git", ".terraform", ".vendor", "node_modules", "graphify-out", "__pycache__", ".venv"}
CHART_REF_RE = re.compile(r"charts/([A-Za-z0-9._-]+)")   # same rule as tools/changeset/graph.py
CONTRACT_FILE_RE = re.compile(r"^(?P<name>.+)\.v(?P<ver>\d+)\.schema\.json$")
TEMPLATE_RE = re.compile(r"^\s*-?\s*template:\s*['\"]?([^'\"#\s]+)", re.MULTILINE)


# --------------------------------------------------------------------------------------------- ids / records
def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_") or "x"


class Graph:
    """Accumulates nodes/links in graphify's node-link JSON shape (deterministic output order)."""

    def __init__(self) -> None:
        self.nodes: Dict[str, dict] = {}
        self.raw_keys: Dict[str, Tuple[str, str]] = {}
        self.links: Dict[Tuple[str, str, str], dict] = {}

    def node_id(self, kind: str, key: str) -> str:
        nid = f"{PREFIX}{kind}_{slug(key)}"
        prev = self.raw_keys.get(nid)
        if prev is not None and prev != (kind, key):
            # two different keys slug to the same id: disambiguate deterministically
            nid = f"{nid}_{hashlib.sha256(key.encode()).hexdigest()[:8]}"
        self.raw_keys.setdefault(nid, (kind, key))
        return nid

    def add_node(self, kind: str, key: str, label: str, source_file: str, line: Optional[int] = None,
                 file_type: str = "code", **attrs) -> str:
        nid = self.node_id(kind, key)
        if nid in self.nodes:
            return nid
        node = {
            "id": nid,
            "label": label,
            "file_type": file_type,
            "source_file": source_file,
            "source_location": f"L{line}" if line else None,
            "norm_label": label.lower(),
            "_origin": ORIGIN,
            "type": f"iac_{kind}",
        }
        node.update({k: v for k, v in attrs.items() if v not in (None, [], {})})
        self.nodes[nid] = node
        return nid

    def add_link(self, source: str, target: str, relation: str, source_file: str, line: Optional[int] = None,
                 context: Optional[str] = None, weight: float = 1.0) -> None:
        if source == target:
            return
        key = (source, target, relation)
        link = self.links.get(key)
        if link is not None:
            link["weight"] = float(link["weight"] + weight)
            if context and context not in (link.get("context") or "").split(","):
                link["context"] = ",".join(filter(None, [link.get("context"), context]))
            return
        link = {
            "source": source,
            "target": target,
            "relation": relation,
            "confidence": "EXTRACTED",
            "confidence_score": 1.0,
            "source_file": source_file,
            "source_location": f"L{line}" if line else None,
            "weight": float(weight),
            "_origin": ORIGIN,
        }
        if context:
            link["context"] = context
        self.links[key] = link

    def to_json(self) -> dict:
        return {
            "directed": False,
            "multigraph": False,
            "graph": {"schema_version": 1, "generator": "tools/graphify/iac_graph.py"},
            "nodes": [self.nodes[k] for k in sorted(self.nodes)],
            "links": [self.links[k] for k in sorted(self.links)],
            "hyperedges": [],
        }


# --------------------------------------------------------------------------------------------- HCL scanning
def _strip_hcl(text: str) -> str:
    """Blank out comments, string contents and heredoc bodies (keeping newlines and the quote characters), so
    braces and keywords inside them do not confuse the block scanner. Line numbers are preserved."""
    out: List[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "#" or text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            depth = 0
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text.startswith("${", j) or text.startswith("%{", j):
                    depth += 1
                    j += 2
                    continue
                if text[j] == "}" and depth:
                    depth -= 1
                elif text[j] == '"' and not depth:
                    break
                elif text[j] == "\n" and not depth:
                    break   # unterminated: stop at end of line
                j += 1
            out.append('"' + re.sub(r"[^\n]", " ", text[i + 1:j]) + ('"' if j < n and text[j] == '"' else ""))
            i = j + 1 if j < n and text[j] == '"' else j
        elif text.startswith("<<", i) and (m := re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n", text[i:])):
            tag = m.group(1)
            end = re.compile(rf"^[ \t]*{re.escape(tag)}[ \t]*$", re.MULTILINE).search(text, i + m.end())
            j = end.end() if end else n
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


BLOCK_RE = re.compile(r'^[ \t]*(resource|data|module|variable|output|terraform)\b((?:[ \t]+"[^"\n]*")*)[ \t]*\{',
                      re.MULTILINE)


def hcl_blocks(text: str) -> Iterator[Tuple[str, List[str], int, str]]:
    """Top-level blocks as (type, labels, line, raw body text). Labels and body come from the original text, block
    boundaries from the comment/string-stripped text."""
    stripped = _strip_hcl(text)
    pos = 0
    while True:
        m = BLOCK_RE.search(stripped, pos)
        if not m:
            return
        depth, j = 0, m.end() - 1
        while j < len(stripped):
            if stripped[j] == "{":
                depth += 1
            elif stripped[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        labels = re.findall(r'"([^"\n]*)"', text[m.start(2):m.end(2)])
        line = stripped.count("\n", 0, m.start()) + 1
        yield m.group(1), labels, line, text[m.end():j]
        pos = j + 1


ATTR_RE = re.compile(r'^\s*(\w+)\s*=\s*"([^"\n]*)"')


def top_level_attrs(body: str) -> Dict[str, Tuple[str, int]]:
    """String attributes at nesting depth 0 of a block body: name -> (value, 1-based line within body)."""
    out: Dict[str, Tuple[str, int]] = {}
    depth = 0
    for i, (raw, clean) in enumerate(zip(body.split("\n"), _strip_hcl(body).split("\n")), start=1):
        if depth == 0:
            m = ATTR_RE.match(raw)
            if m:
                out.setdefault(m.group(1), (m.group(2), i))
        depth += sum(clean.count(c) for c in "{[(") - sum(clean.count(c) for c in "}])")
    return out


def tf_files(directory: Path) -> List[Path]:
    return sorted(p for p in directory.glob("*.tf") if p.is_file())


def tf_dirs(repo: Path, ignored=None) -> List[str]:
    found = set()
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        rel = Path(root).relative_to(repo).as_posix()
        rel = "" if rel == "." else rel
        if any(f.endswith(".tf") and not (ignored and ignored(posixpath.join(rel, f))) for f in files):
            found.add(rel)
    return sorted(found)


class Ignore:
    """The subset of .graphifyignore (gitignore syntax) the adapter needs: `graphify update` evicts every node whose
    source_file is ignored, so the IaC layer must not be sourced from ignored files either. Supports `dir/`,
    `**/dir/`, globs (`**/*.lock.hcl`) and plain paths; negation (`!`) is not supported (and not used)."""

    def __init__(self, repo: Path) -> None:
        self.patterns: List[Tuple[str, bool, bool]] = []   # (glob, directory-only, anchored)
        f = repo / ".graphifyignore"
        lines = f.read_text(encoding="utf-8").splitlines() if f.exists() else []
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith(("#", "!")):
                continue
            dir_only = line.endswith("/")
            line = line.strip("/")
            anchored = "/" in line and not line.startswith("**/")
            self.patterns.append((line[3:] if line.startswith("**/") else line, dir_only, anchored))

    def __call__(self, path: str) -> bool:
        parts = path.strip("/").split("/")
        for glob, dir_only, anchored in self.patterns:
            n = glob.count("/") + 1
            for i in [0] if anchored else range(len(parts) - n + 1):
                end = i + n
                if dir_only and end >= len(parts):
                    continue   # `dir/` only matches a directory, i.e. a proper prefix of the path
                if fnmatch.fnmatchcase("/".join(parts[i:end]), glob):
                    return True
        return False


# --------------------------------------------------------------------------------------------- YAML helpers
def load_yaml(path: Path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        print(f"iac_graph: skipping {path}: {exc}", file=sys.stderr)
        return None


def line_of(text: str, pattern: str, start: int = 0) -> Optional[int]:
    m = re.compile(pattern, re.MULTILINE).search(text, start)
    return text.count("\n", 0, m.start()) + 1 if m else None


def id_lines(text: str) -> Dict[str, int]:
    """`- id: <x>` -> line number (first occurrence)."""
    out: Dict[str, int] = {}
    for m in re.finditer(r"^\s*-\s+id:\s*['\"]?([A-Za-z0-9._-]+)", text, re.MULTILINE):
        out.setdefault(m.group(1), text.count("\n", 0, m.start()) + 1)
    return out


def rel(repo: Path, p: Path) -> str:
    return p.relative_to(repo).as_posix()


# --------------------------------------------------------------------------------------------- builder
class Builder:
    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self.g = Graph()
        self.ignored = Ignore(repo)
        self.components: Dict[str, dict] = {}
        self.comp_nodes: Dict[str, str] = {}
        self.dir_nodes: Dict[str, str] = {}       # tf directory -> component or module node id
        self.artifact_nodes: Dict[str, str] = {}  # artifact component id -> artifact node id
        self.contract_nodes: Dict[str, str] = {}

    # ---- registry
    def components_registry(self) -> None:
        path = self.repo / "catalog/components.yaml"
        if not path.exists():
            return
        text = path.read_text(encoding="utf-8")
        lines = id_lines(text)
        doc = yaml.safe_load(text) or {}
        src = "catalog/components.yaml"
        for c in doc.get("components") or []:
            cid = str(c.get("id"))
            self.components[cid] = c
            kind = c.get("kind", "terraform")
            what = {"terraform": "terraform root", "artifact": "artifact build", "docs": "docs"}.get(kind, kind)
            nid = self.g.add_node("component", cid, f"{cid} component ({what})", src, lines.get(cid),
                                  layer=c.get("layer"), component_kind=kind, path=c.get("path"), scope=c.get("scope"),
                                  optional=c.get("optional"))
            self.comp_nodes[cid] = nid
            if kind == "terraform" and c.get("path"):
                self.dir_nodes[str(c["path"]).rstrip("/")] = nid
            art = c.get("artifact")
            if kind == "artifact" and isinstance(art, dict):
                types = [art.get("type")] + list(art.get("also") or [])
                aid = self.g.add_node("artifact", cid, f"{art.get('name', cid)} artifact ({', '.join(filter(None, types))})",
                                      src, lines.get(cid), file_type="concept", artifact_name=art.get("name"),
                                      artifact_types=[t for t in types if t])
                self.artifact_nodes[cid] = aid
                self.g.add_link(nid, aid, "builds", src, lines.get(cid))
        # contracts produced (from the registry) + schema files
        producers: Dict[str, List[str]] = {}
        for cid, c in self.components.items():
            for name in c.get("produces") or []:
                producers.setdefault(str(name), []).append(cid)
        self.contracts(producers)
        for cid, c in self.components.items():
            nid, ln = self.comp_nodes[cid], lines.get(cid)
            for name in c.get("produces") or []:
                self.g.add_link(nid, self.contract_node(str(name)), "produces_contract", src, ln)
            for field, ctx in (("consumes", None), ("optional_consumes", "optional")):
                for name in c.get(field) or []:
                    name = str(name)
                    self.g.add_link(nid, self.contract_node(name), "consumes_contract", src, ln, context=ctx)
                    for prod in producers.get(name, []):
                        self.g.add_link(nid, self.comp_nodes[prod], "consumes", src, ln, context=ctx)
            for dep in c.get("depends_on") or []:
                if str(dep) in self.comp_nodes:
                    self.g.add_link(nid, self.comp_nodes[str(dep)], "depends_on", src, ln)
            for art in c.get("artifacts") or []:
                target = self.artifact_nodes.get(str(art)) or self.comp_nodes.get(str(art))
                if target:
                    self.g.add_link(nid, target, "consumes_artifact", src, ln)

    def contract_node(self, name: str) -> str:
        if name not in self.contract_nodes:
            self.contract_nodes[name] = self.g.add_node("contract", name, f"{name} contract",
                                                        "catalog/components.yaml", None, file_type="concept")
        return self.contract_nodes[name]

    def contracts(self, producers: Dict[str, List[str]]) -> None:
        base = self.repo / "catalog/contracts"
        versions: Dict[str, List[Tuple[int, str]]] = {}
        if base.is_dir():
            for f in sorted(base.glob("*.schema.json")):
                m = CONTRACT_FILE_RE.match(f.name)
                if m:
                    versions.setdefault(m.group("name"), []).append((int(m.group("ver")), rel(self.repo, f)))
        for name in sorted(set(versions) | set(producers)):
            vs = sorted(versions.get(name, []))
            src = vs[-1][1] if vs else "catalog/components.yaml"
            self.contract_nodes[name] = self.g.add_node(
                "contract", name, f"{name} contract", src, 1 if vs else None, file_type="concept",
                versions=[v for v, _ in vs], schema_files=[p for _, p in vs])

    # ---- catalog services referenced by components
    def services(self) -> None:
        refs: Dict[str, List[str]] = {}
        for cid, c in self.components.items():
            for r in c.get("catalog_refs") or []:
                refs.setdefault(str(r), []).append(cid)
        if not refs:
            return
        for f in sorted((self.repo / "catalog/services").glob("*.yaml")):
            text = f.read_text(encoding="utf-8")
            lines = id_lines(text)
            doc = yaml.safe_load(text) or {}
            for s in doc.get("services") or []:
                sid = str(s.get("id"))
                if sid not in refs:
                    continue
                nid = self.g.add_node("service", sid, f"{s.get('display_name') or sid} (catalog service {sid})",
                                      rel(self.repo, f), lines.get(sid), file_type="concept",
                                      category=s.get("category"))
                for cid in refs[sid]:
                    self.g.add_link(self.comp_nodes[cid], nid, "implements_service", "catalog/components.yaml",
                                    None)

    # ---- terraform
    def terraform(self, base_graph: Optional[dict] = None) -> None:
        dirs = tf_dirs(self.repo, self.ignored)
        for d in dirs:
            if d not in self.dir_nodes:
                files = [f for f in tf_files(self.repo / d) if not self.ignored(rel(self.repo, f))]
                main = next((f for f in files if f.name == "main.tf"), files[0])
                self.dir_nodes[d] = self.g.add_node("tfmodule", d, f"{d or '.'} terraform module", rel(self.repo, main),
                                                    1, path=d)
        native = {}
        for n in (base_graph or {}).get("nodes", []):
            if n.get("type") == "module" and n.get("_terraform_directory") is not None:
                native[n["_terraform_directory"]] = n["id"]
        for d in dirs:
            owner = self.dir_nodes[d]
            counts = {"variable": 0, "output": 0}
            for f in tf_files(self.repo / d):
                src = rel(self.repo, f)
                if self.ignored(src):
                    continue
                text = f.read_text(encoding="utf-8", errors="replace")
                for btype, labels, line, body in hcl_blocks(text):
                    if btype in counts:
                        counts[btype] += 1
                    elif btype in ("resource", "data") and labels:
                        kind = "tfresource" if btype == "resource" else "tfdata"
                        what = "resource type" if btype == "resource" else "data source"
                        tid = self.g.add_node(kind, labels[0], f"{labels[0]} {what}", src, line, file_type="concept",
                                              provider=labels[0].split("_", 1)[0])
                        self.g.add_link(owner, tid, "declares_resource", src, line, context=btype)
                    elif btype == "module":
                        attrs = top_level_attrs(body)
                        if "source" not in attrs:
                            continue
                        source, sline = attrs["source"][0], line + attrs["source"][1] - 1
                        if source.startswith(("./", "../")):
                            target = posixpath.normpath(posixpath.join(d, source.split("//")[0]))
                            target = "" if target == "." else target
                            tnode = self.dir_nodes.get(target)
                            if tnode is None:
                                continue   # source outside the repo or without .tf files
                        else:
                            tnode = self.g.add_node("tfmodule_ext", source, f"{source} terraform registry module",
                                                    src, sline, file_type="concept", version=attrs.get("version", (None,))[0])
                        self.g.add_link(owner, tnode, "uses_module", src, sline, context=labels[0] if labels else None)
                    elif btype == "terraform":
                        rp = re.search(r"required_providers\s*\{", body)
                        if rp:
                            for m in re.finditer(r'^\s*source\s*=\s*"([^"\n]+)"', body[rp.end():], re.MULTILINE):
                                pline = line + body.count("\n", 0, rp.end() + m.start()) + 0
                                pid = self.g.add_node("tfprovider", m.group(1), f"{m.group(1)} terraform provider",
                                                      src, pline, file_type="concept")
                                self.g.add_link(owner, pid, "requires_provider", src, pline)
                for name in sorted(set(CHART_REF_RE.findall(text))):
                    chart = self.repo / "applications/charts" / name
                    if (chart / "Chart.yaml").exists():
                        cline = line_of(text, re.escape(f"charts/{name}"))
                        self.g.add_link(owner, self.chart_node(name), "deploys_chart", src, cline)
            node = self.g.nodes[owner]
            node["tf_variables"], node["tf_outputs"] = counts["variable"], counts["output"]
            if d in native:
                self.g.add_link(owner, native[d], "implemented_by", node["source_file"], None)

    def chart_node(self, name: str) -> str:
        chart = self.repo / "applications/charts" / name / "Chart.yaml"
        meta = load_yaml(chart) or {}
        return self.g.add_node("helmchart", name, f"{name} helm chart", rel(self.repo, chart), 1,
                               version=str(meta.get("version")) if meta.get("version") else None)

    def charts(self) -> None:
        for chart in sorted((self.repo / "applications/charts").glob("*/Chart.yaml")):
            self.chart_node(chart.parent.name)

    # ---- pipelines
    def pipelines(self) -> None:
        files = sorted(self.repo.glob("azure-pipelines*.yml")) + sorted((self.repo / "pipelines").rglob("*.yml"))
        files = [f for f in files if not self.ignored(rel(self.repo, f))]   # e.g. pipelines/generated/
        nodes: Dict[str, str] = {}

        def pnode(path: str, line: Optional[int] = 1) -> str:
            if path not in nodes:
                nodes[path] = self.g.add_node("pipeline", path, f"{path} pipeline", path, 1)
            return nodes[path]

        for f in files:
            path = rel(self.repo, f)
            pnode(path)
        for f in files:
            path = rel(self.repo, f)
            text = f.read_text(encoding="utf-8", errors="replace")
            here = pnode(path)
            for m in TEMPLATE_RE.finditer(text):
                ref = m.group(1)
                if "${{" in ref or "@" in ref:
                    continue
                target = ref.lstrip("/") if ref.startswith("/") else posixpath.normpath(
                    posixpath.join(posixpath.dirname(path), ref))
                if not (self.repo / target).is_file() or self.ignored(target):
                    continue
                line = text.count("\n", 0, m.start()) + 1
                self.g.add_link(here, pnode(target), "uses_template", path, line)
            # template invocations that deploy a registry component (generated stages)
            doc = None
            if "component:" in text:
                try:
                    doc = yaml.safe_load(text)
                except yaml.YAMLError:
                    doc = None
            for tmpl, comp in _component_invocations(doc):
                cnode = self.comp_nodes.get(comp)
                if cnode:
                    line = line_of(text, rf"^\s*component:\s*['\"]?{re.escape(comp)}['\"]?\s*$")
                    self.g.add_link(here, cnode, "runs_component", path, line, context=posixpath.basename(tmpl))

    # ---- environments / profiles
    def profiles(self) -> None:
        for f in sorted((self.repo / "environments/profiles").glob("*.yaml")):
            text = f.read_text(encoding="utf-8")
            doc = yaml.safe_load(text) or {}
            name = str(doc.get("profile") or f.stem)
            src = rel(self.repo, f)
            pid = self.g.add_node("profile", name, f"{name} deployment profile", src, 1, file_type="concept",
                                  expensive=doc.get("expensive"))
            for cid in doc.get("components") or []:
                if str(cid) in self.comp_nodes:
                    self.g.add_link(pid, self.comp_nodes[str(cid)], "enables", src,
                                    line_of(text, rf"^\s*-\s*{re.escape(str(cid))}\s*$"))
        for f in sorted((self.repo / "environments").glob("*/environment.yaml")):
            text = f.read_text(encoding="utf-8")
            doc = yaml.safe_load(text) or {}
            env = str((doc.get("environment") or {}).get("name") or f.parent.name)
            src = rel(self.repo, f)
            eid = self.g.add_node("environment", env, f"{env} environment", src, 1, file_type="concept")
            prof = doc.get("profile")
            if prof:
                pid = self.g.node_id("profile", str(prof))
                if pid in self.g.nodes:
                    self.g.add_link(eid, pid, "uses_profile", src, line_of(text, r"^profile:"))
            for cid in doc.get("custom_components") or []:
                if str(cid) in self.comp_nodes:
                    self.g.add_link(eid, self.comp_nodes[str(cid)], "enables", src, line_of(text, r"^custom_components:"))

    def link_schemas(self, base_graph: Optional[dict]) -> None:
        """contract -> graphify's own AST node of each schema file (has_schema)."""
        files = {}
        for n in (base_graph or {}).get("nodes", []):
            sf = n.get("source_file") or ""
            if sf.startswith("catalog/contracts/") and n.get("label") == posixpath.basename(sf):
                files[sf] = n["id"]
        for name, nid in sorted(self.contract_nodes.items()):
            for sf in self.g.nodes[nid].get("schema_files", []):
                if sf in files:
                    self.g.add_link(nid, files[sf], "has_schema", sf, 1)

    def build(self, base_graph: Optional[dict] = None) -> dict:
        self.components_registry()
        self.services()
        self.charts()
        self.terraform(base_graph)
        self.pipelines()
        self.profiles()
        self.link_schemas(base_graph)
        return self.g.to_json()


def _component_invocations(doc) -> Iterator[Tuple[str, str]]:
    stack = [doc]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            t, p = cur.get("template"), cur.get("parameters")
            if isinstance(t, str) and isinstance(p, dict) and isinstance(p.get("component"), str):
                yield t, p["component"]
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)


# --------------------------------------------------------------------------------------------- merge
def merge_into(base: dict, layer: dict) -> dict:
    """Replace the IaC layer of a graphify graph.json (nodes with an `iac_` id and every link touching one) by
    `layer`. Same-repo merge: ids are kept as-is (unlike `graphify merge-graphs`, which repo-prefixes every id for
    cross-repo graphs and would break `graphify update` incrementality and the links to AST nodes)."""
    keep_nodes = [n for n in base.get("nodes", []) if not str(n.get("id", "")).startswith(PREFIX)]
    ids = {n["id"] for n in keep_nodes}
    key = "links" if "links" in base or "edges" not in base else "edges"
    keep_links = [l for l in base.get(key, []) if not (str(l.get("source", "")).startswith(PREFIX)
                                                       or str(l.get("target", "")).startswith(PREFIX))]
    new_ids = ids | {n["id"] for n in layer["nodes"]}
    links = [l for l in layer["links"] if l["source"] in new_ids and l["target"] in new_ids]
    out = dict(base)
    out["nodes"] = keep_nodes + layer["nodes"]
    out[key] = keep_links + links
    return out


def stats(g: dict) -> str:
    rels: Dict[str, int] = {}
    for l in g["links"]:
        rels[l["relation"]] = rels.get(l["relation"], 0) + 1
    kinds: Dict[str, int] = {}
    for n in g["nodes"]:
        kinds[n["type"]] = kinds.get(n["type"], 0) + 1
    return (f"{len(g['nodes'])} nodes, {len(g['links'])} links\n  nodes: "
            + ", ".join(f"{k}={v}" for k, v in sorted(kinds.items()))
            + "\n  links: " + ", ".join(f"{k}={v}" for k, v in sorted(rels.items())))


def main(argv: Optional[Iterable[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=str(REPO), help="repository root (default: this repository)")
    ap.add_argument("--out", required=True, help="write the IaC layer graph JSON here")
    ap.add_argument("--merge-into", metavar="GRAPH_JSON",
                    help="also replace the IaC layer of this graphify graph.json in place (and link to its "
                         "native Terraform module nodes)")
    args = ap.parse_args(list(argv) if argv is not None else None)
    repo = Path(args.repo).resolve()
    base = None
    if args.merge_into:
        bp = Path(args.merge_into)
        if not bp.exists():
            print(f"iac_graph: --merge-into {bp} not found (run graphify first)", file=sys.stderr)
            return 2
        base = json.loads(bp.read_text(encoding="utf-8"))
    layer = Builder(repo).build(base)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(layer, indent=1, sort_keys=False) + "\n", encoding="utf-8")
    print(f"iac_graph: {out}: {stats(layer)}")
    if base is not None:
        merged = merge_into(base, layer)
        tmp = Path(args.merge_into + ".tmp")
        tmp.write_text(json.dumps(merged, indent=2), encoding="utf-8")
        os.replace(tmp, args.merge_into)
        print(f"iac_graph: merged into {args.merge_into}: {len(merged['nodes'])} nodes, "
              f"{len(merged.get('links', merged.get('edges', [])))} links")
    return 0


if __name__ == "__main__":
    sys.exit(main())
