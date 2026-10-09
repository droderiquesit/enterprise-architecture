"""Selection: decide what each pipeline run validates, plans, applies, builds and retires.

Modes
  pr         merge-base(origin/<target>, HEAD)..HEAD (rename-aware). Fingerprints of base and head are
             compared per component; changed paths are attributed to owners (old and new paths).
             validate = changed ∪ transitive consumers of infrastructure changes; plan flags are
             informational (PR builds never receive credentials); nothing is applied.
  deploy     current deploy_fp of every enabled component vs its last deployment record
             (<env>/<component>.json). No record / status != succeeded / fp differs → selected.
             Consumers of infrastructure changes are planned; apply happens only when the plan has
             changes (terraform -detailed-exitcode == 2).
  manual     explicit list (+ upstream planned without apply; --with-consumers adds consumers).
  reconcile  every enabled component planned, applied only where the plan has changes.
  drift      every enabled component planned, nothing applied; the run reports drift.
  retire     only scheduled retirements.

A change that only touches a deploy root's artifact digests (new image of an app) re-deploys
that root but does not re-plan its consumers: artifacts do not change Terraform contracts.
"""

from __future__ import annotations

import datetime as _dt
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from . import globs
from .fingerprint import Fingerprinter, changed_parts, deploy_relevant, is_doc
from .gitdiff import diff, merge_base, resolve_target_ref, rev_parse
from .graph import Graph
from .registry import Registry, RegistryError, load_registry
from .store import Store
from .trees import GitTree, Tree, WorkTree

MODES = ("pr", "deploy", "manual", "reconcile", "drift", "retire")
TOOLING_PATHS = ("tools/", "pipelines/", "azure-pipelines.yml", "tests/", "catalog/schemas/", "environments/schema/")
SUCCEEDED = "succeeded"


class SelectionError(Exception):
    pass


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_env(tree: Tree, registry: Registry, graph: Graph, env: str):
    from tools.config.lib import resolve_for_env

    return resolve_for_env(tree, registry, graph, env)


class Context:
    def __init__(self, repo: Path, env: str, head: str = "HEAD", worktree: bool = False,
                 artifact_digests: Optional[Dict[str, str]] = None):
        self.repo = Path(repo).resolve()
        self.env = env
        if worktree or not (self.repo / ".git").exists():
            self.tree: Tree = WorkTree(self.repo)
            self.head = None
        else:
            self.tree = GitTree(self.repo, head)
            self.head = self.tree.rev
        self.registry = load_registry(self.tree)
        self.graph = Graph(self.registry)
        self.graph.check_acyclic()
        self.enabled, self.env_doc, self.profile_doc, self.notes = _load_env(self.tree, self.registry, self.graph, env)
        self.fp = Fingerprinter(self.tree, self.registry, self.graph, env, self.env_doc, self.profile_doc,
                                self.enabled, artifact_digests)
        self.layer_of = self.graph.layer_index()


def _entry(ctx: Context, cid: str) -> dict:
    c = ctx.registry.get(cid)
    return {
        "id": cid,
        "kind": c.kind,
        "layer_name": c.layer,
        "path": c.path,
        "enabled": cid in ctx.enabled,
        "validate": False,
        "plan": False,
        "apply_candidate": False,
        "build": False,
        "reason": [],
        "deploy_fp": ctx.fp.deploy_fp(cid) if not c.is_docs else None,
        "validation_fp": ctx.fp.validation_fp(cid),
        "fp_parts": ctx.fp.parts(cid) if not c.is_docs else None,
        "previous_fp": None,
        "changed_parts": [],
        "layer": ctx.layer_of.get(cid, 0),
        "wave": None,
        "timeout_minutes": c.timeout_minutes,
    }


def _add_reason(e: dict, reason: str) -> None:
    if reason not in e["reason"]:
        e["reason"].append(reason)


def _infra_change(parts: Iterable[str]) -> bool:
    return any(p != "artifacts" for p in parts)


def _finish(ctx: Context, doc: dict) -> dict:
    comps = doc["components"]
    planned = [cid for cid, e in comps.items() if e["plan"]]
    waves = ctx.graph.layers(nodes=planned, enabled=ctx.enabled) if planned else []
    for i, wave in enumerate(waves):
        for cid in wave:
            comps[cid]["wave"] = i
    doc["waves"] = waves
    doc["artifacts_to_build"] = sorted(cid for cid, e in comps.items() if e["build"])
    doc["summary"] = {
        "validate": sorted(cid for cid, e in comps.items() if e["validate"]),
        "plan": sorted(planned),
        "apply_candidates": sorted(cid for cid, e in comps.items() if e["apply_candidate"]),
        "build": doc["artifacts_to_build"],
        "retire_scheduled": [r["component"] for r in doc.get("retirements", []) if r["status"] == "retire-scheduled"],
    }
    return doc


def _base_doc(ctx: Context, mode: str) -> dict:
    return {
        "schema_version": 1,
        "mode": mode,
        "environment": ctx.env,
        "profile": ctx.profile_doc.get("profile"),
        "enabled": sorted(ctx.enabled),
        "base": None,
        "head": ctx.head,
        "generated_at": _now(),
        "notes": list(ctx.notes),
        "components": {c.id: _entry(ctx, c.id) for c in ctx.registry if c.pipeline != "manual"},
        "removed_components": [],
        "retirements": [],
        "tooling_changed": False,
        "changed_files": [],
    }


def _plan(ctx: Context, doc: dict, cid: str, reason: str, apply: bool) -> None:
    c = ctx.registry.get(cid)
    if not c.deployable or cid not in ctx.enabled:
        return
    e = doc["components"][cid]
    e["plan"] = True
    e["apply_candidate"] = e["apply_candidate"] or apply
    _add_reason(e, reason)


def _artifacts_for_planned(ctx: Context, doc: dict) -> None:
    for cid, e in doc["components"].items():
        if not e["plan"]:
            continue
        for a in ctx.registry.get(cid).artifacts:
            ae = doc["components"][a]
            ae["build"] = True
            _add_reason(ae, f"required by planned {cid} (resolve existing digest or build)")


# ------------------------------------------------------------------------ PR
def select_pr(repo: Path, env: str, target: str = "main", head: str = "HEAD", base: Optional[str] = None) -> dict:
    ctx = Context(repo, env, head)
    doc = _base_doc(ctx, "pr")
    if base is None:
        target_ref = resolve_target_ref(ctx.repo, target)
        base = merge_base(ctx.repo, target_ref, ctx.head)
        doc["target"] = target_ref
    else:
        base = rev_parse(ctx.repo, base)
    doc["base"] = base
    changes = diff(ctx.repo, base, ctx.head)
    doc["changed_files"] = [{"status": ch.status, "path": ch.path, "old_path": ch.old_path} for ch in changes]
    base_tree = GitTree(ctx.repo, base)
    base_fp = None
    base_registry = None
    try:
        base_registry = load_registry(base_tree)
        base_graph = Graph(base_registry)
        try:
            b_enabled, b_env, b_profile, _ = _load_env(base_tree, base_registry, base_graph, env)
        except Exception:  # noqa: BLE001 - environment new or invalid at base
            b_enabled, b_env, b_profile = None, None, None
        base_fp = Fingerprinter(base_tree, base_registry, base_graph, env, b_env, b_profile, b_enabled)
    except RegistryError as exc:
        doc["notes"].append(f"base registry unreadable ({exc}); every component treated as changed")

    all_paths = [p for ch in changes for p in ch.paths]
    doc["tooling_changed"] = any(p.startswith(TOOLING_PATHS) or p == "azure-pipelines.yml" for p in all_paths)
    comps = doc["components"]

    # 1. direct ownership of changed paths (old path → owner at base, new path → owner at head)
    for ch in changes:
        for p in ch.paths:
            for c in ctx.registry:
                if c.id in comps and ctx.fp.owns(c, p):
                    _add_reason(comps[c.id], f"{ch.status}: {p}")
                    comps[c.id]["validate"] = True
            if base_registry is not None and base_fp is not None:
                for c in base_registry:
                    if c.id in comps and c.id not in ctx.registry.components:
                        continue
                    if c.id in comps and base_fp.owns(c, p):
                        _add_reason(comps[c.id], f"{ch.status}: {p} (owned at base)")
                        comps[c.id]["validate"] = True

    # 2. fingerprint comparison (catches config, versions, shared modules, registry edits)
    infra_changed: Set[str] = set()
    for cid, e in comps.items():
        c = ctx.registry.get(cid)
        if base_registry is None or cid not in base_registry.components:
            e["validate"] = True
            _add_reason(e, "new component")
            if not c.is_docs:
                e["changed_parts"] = sorted(e["fp_parts"])
                infra_changed.add(cid)
            continue
        if base_fp.validation_fp(cid) != e["validation_fp"]:
            e["validate"] = True
            parts = changed_parts(base_fp.validation_parts(cid), ctx.fp.validation_parts(cid))
            _add_reason(e, "validation inputs changed: " + ",".join(parts))
        if c.is_docs:
            continue
        e["previous_fp"] = base_fp.deploy_fp(cid)
        if e["previous_fp"] != e["deploy_fp"]:
            parts = changed_parts(base_fp.parts(cid), e["fp_parts"])
            e["changed_parts"] = parts
            _add_reason(e, "deploy inputs changed: " + ",".join(parts))
            if c.is_artifact:
                e["build"] = True
            elif _infra_change(parts):
                infra_changed.add(cid)
            if c.deployable:
                _plan(ctx, doc, cid, "deploy inputs changed", apply=False)

    # 3. consumers of infrastructure changes: validate (all registry) / plan (enabled only)
    for cid in sorted(infra_changed):
        for d in sorted(ctx.graph.transitive_consumers([cid], include_implicit=False)):
            if d not in comps or ctx.registry.get(d).is_artifact:
                continue
            comps[d]["validate"] = True
            _add_reason(comps[d], f"consumer of changed {cid}")
            _plan(ctx, doc, d, f"consumer of changed {cid}", apply=False)
    if base_registry is not None:
        for c in base_registry:
            if c.id not in ctx.registry.components and c.pipeline != "manual":
                doc["removed_components"].append({
                    "component": c.id,
                    "note": "removed from registry: becomes retire-pending once a deployment record exists; "
                            "never destroyed without environments/<env>/retirements.yaml",
                })
    return _finish(ctx, doc)


# -------------------------------------------------------------------- DEPLOY
def _record(store: Optional[Store], env: str, cid: str) -> Optional[dict]:
    if store is None:
        return None
    return store.get_json(f"{env}/{cid}.json")


def _retirements(ctx: Context, doc: dict, store: Optional[Store]) -> None:
    if store is None:
        return
    from tools.config.lib import load_retirements

    approved = {}
    for r in load_retirements(ctx.tree, ctx.env):
        approved[r["component"]] = r
    records = {}
    for key in store.list(f"{ctx.env}/"):
        if not key.endswith(".json") or key.count("/") != 1:
            continue
        cid = key.split("/", 1)[1][:-5]
        rec = store.get_json(key) or {}
        if rec.get("status") == "retired":
            continue
        if rec.get("kind") == "artifact":
            continue
        if cid in ctx.enabled:
            continue
        records[cid] = rec
    entries = []
    for cid, rec in sorted(records.items()):
        in_registry = cid in ctx.registry.components
        entry = {
            "component": cid,
            "in_registry": in_registry,
            "path": rec.get("path") or (ctx.registry.get(cid).path if in_registry else None),
            "record_commit": rec.get("commit"),
            "record_status": rec.get("status"),
            "upstream": rec.get("upstream", []),
            "status": "retire-pending",
            "reason": "deployment record exists but component is "
                      + ("not enabled in this environment" if in_registry else "no longer in the registry"),
            "approval": None,
            "order": None,
        }
        blockers = []
        if in_registry:
            for d, kind in ctx.graph.consumers(cid, include_implicit=False).items():
                if d in ctx.enabled and kind in ("hard", "artifact"):
                    blockers.append(d)
        produced = set(rec.get("produces") or [])
        for c in ctx.registry:
            if c.id in ctx.enabled and produced & set(c.consumes) - set(c.optional_consumes):
                blockers.append(c.id)
        appr = approved.get(cid)
        if blockers:
            entry["status"] = "retire-blocked"
            entry["reason"] = "enabled components still depend on it: " + ", ".join(sorted(set(blockers)))
        elif appr:
            if appr.get("confirm") != cid:
                entry["reason"] += f"; retirements.yaml entry ignored: confirm '{appr.get('confirm')}' != '{cid}'"
            else:
                entry["status"] = "retire-scheduled"
                entry["approval"] = {k: appr.get(k) for k in ("approved_by", "reason", "change_ref") if appr.get(k)}
        entries.append(entry)
    # consumers retire first: order scheduled entries so nothing is destroyed before its consumers
    scheduled = {e["component"]: e for e in entries if e["status"] == "retire-scheduled"}
    order: List[str] = []
    remaining = set(scheduled)
    while remaining:
        ready = sorted(cid for cid in remaining
                       if not any(cid in scheduled[o]["upstream"] for o in remaining if o != cid))
        if not ready:  # cycle in historical records: refuse rather than guess
            for cid in remaining:
                scheduled[cid]["status"] = "retire-blocked"
                scheduled[cid]["reason"] = "cannot order retirement (cyclic upstream in records)"
            break
        for cid in ready:
            order.append(cid)
            remaining.discard(cid)
    for i, cid in enumerate(order):
        scheduled[cid]["order"] = i
    entries.sort(key=lambda e: (e["order"] is None, e["order"] if e["order"] is not None else 0, e["component"]))
    doc["retirements"] = entries


def select_deploy(repo: Path, env: str, store: Optional[Store], head: str = "HEAD",
                  artifact_digests: Optional[Dict[str, str]] = None, worktree: bool = False) -> dict:
    ctx = Context(repo, env, head, worktree=worktree, artifact_digests=artifact_digests)
    doc = _base_doc(ctx, "deploy")
    if store is None:
        doc["notes"].append("no record store given: every enabled component is treated as never deployed")
    comps = doc["components"]
    infra_changed: Set[str] = set()
    for cid, e in comps.items():
        c = ctx.registry.get(cid)
        if cid not in ctx.enabled or not (c.deployable or c.is_artifact):
            continue
        rec = _record(store, env, cid)
        if rec is None:
            reason, parts = "no deployment record", sorted(e["fp_parts"])
        elif rec.get("status") != SUCCEEDED:
            reason, parts = f"previous deployment status={rec.get('status')}", sorted(e["fp_parts"])
            e["previous_fp"] = (rec.get("last_succeeded") or {}).get("deploy_fp") or rec.get("deploy_fp")
        else:
            e["previous_fp"] = rec.get("deploy_fp")
            if rec.get("deploy_fp") == e["deploy_fp"]:
                continue
            parts = changed_parts(rec.get("fp_parts"), e["fp_parts"])
            reason = "deploy fingerprint changed: " + ",".join(parts)
        e["changed_parts"] = parts
        _add_reason(e, reason)
        e["validate"] = True
        if c.is_artifact:
            e["build"] = True
            continue
        _plan(ctx, doc, cid, reason, apply=True)
        if _infra_change(parts):
            infra_changed.add(cid)
    for cid in sorted(infra_changed):
        for d in sorted(ctx.graph.transitive_consumers([cid], enabled=ctx.enabled)):
            if ctx.registry.get(d).deployable:
                _plan(ctx, doc, d, f"upstream {cid} changed (apply only if plan has changes)", apply=True)
    _artifacts_for_planned(ctx, doc)
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


# -------------------------------------------------------------------- MANUAL
def select_manual(repo: Path, env: str, components: List[str], with_consumers: bool = False,
                  store: Optional[Store] = None, head: str = "HEAD", worktree: bool = False) -> dict:
    ctx = Context(repo, env, head, worktree=worktree)
    doc = _base_doc(ctx, "manual")
    if not components:
        raise SelectionError("manual mode needs --components")
    for cid in components:
        if cid not in ctx.registry:
            raise SelectionError(f"unknown component '{cid}'")
        c = ctx.registry.get(cid)
        if c.is_artifact:
            doc["components"][cid]["build"] = True
            _add_reason(doc["components"][cid], "requested")
            for d, kind in ctx.graph.consumers(cid).items():
                if kind == "artifact":
                    _plan(ctx, doc, d, f"deploys requested artifact {cid}", apply=True)
            continue
        if not c.deployable:
            raise SelectionError(f"'{cid}' is not deployable by the pipeline (kind={c.kind}, pipeline={c.pipeline})")
        if cid not in ctx.enabled:
            raise SelectionError(f"'{cid}' is not enabled in environment '{env}' (profile {ctx.profile_doc.get('profile')})")
        _plan(ctx, doc, cid, "requested", apply=True)
    requested = [c for c in components if ctx.registry.get(c).deployable]
    for cid in requested:
        for up in sorted(ctx.graph.transitive_upstream(cid, ctx.enabled)):
            if ctx.registry.get(up).deployable and not doc["components"][up]["plan"]:
                _plan(ctx, doc, up, f"upstream of requested {cid} (plan only)", apply=False)
    if with_consumers:
        for d in sorted(ctx.graph.transitive_consumers(requested, enabled=ctx.enabled)):
            _plan(ctx, doc, d, "consumer of requested component (--with-consumers)", apply=True)
    for e in doc["components"].values():
        if e["plan"]:
            e["validate"] = True
    _artifacts_for_planned(ctx, doc)
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


# --------------------------------------------------------- RECONCILE / DRIFT
def select_all(repo: Path, env: str, mode: str, store: Optional[Store] = None, head: str = "HEAD",
               worktree: bool = False) -> dict:
    assert mode in ("reconcile", "drift")
    ctx = Context(repo, env, head, worktree=worktree)
    doc = _base_doc(ctx, mode)
    for c in ctx.registry:
        if c.deployable and c.id in ctx.enabled:
            reason = "reconcile: plan every enabled component" if mode == "reconcile" else "drift detection (plan only)"
            _plan(ctx, doc, c.id, reason, apply=(mode == "reconcile"))
            rec = _record(store, env, c.id)
            if rec:
                doc["components"][c.id]["previous_fp"] = rec.get("deploy_fp")
    _artifacts_for_planned(ctx, doc)
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


def select_retire(repo: Path, env: str, store: Optional[Store], head: str = "HEAD", worktree: bool = False) -> dict:
    ctx = Context(repo, env, head, worktree=worktree)
    doc = _base_doc(ctx, "retire")
    if store is None:
        raise SelectionError("retire mode needs the deployment record store (--records-dir/--records-url)")
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


def auto_mode(build_reason: Optional[str]) -> str:
    if build_reason == "PullRequest":
        return "pr"
    if build_reason == "Schedule":
        return "drift"
    return "deploy"


def docs_only(paths: Iterable[str]) -> bool:
    paths = list(paths)
    return bool(paths) and all(is_doc(p) or globs.under(p, "docs") for p in paths)


__all__ = [
    "MODES", "SelectionError", "select_pr", "select_deploy", "select_manual", "select_all", "select_retire",
    "auto_mode", "docs_only", "deploy_relevant",
]
