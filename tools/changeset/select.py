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
  promote    deploy-mode selection for a later environment of a promotion chain, refused unless the
             source environment successfully deployed the same code (select_promote).
Every mode can be restricted to one pipeline scope (platform | applications); see _scope_filter.

A change that only touches a deploy root's artifact digests (new image of an app) re-deploys
that root but does not re-plan its consumers: artifacts do not change Terraform contracts.
"""

from __future__ import annotations

import datetime as _dt
import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from . import globs
from .fingerprint import Fingerprinter, changed_parts, deploy_relevant, is_doc
from .gitdiff import diff, merge_base, resolve_target_ref, rev_parse
from .graph import Graph
from .registry import SCOPES, Registry, RegistryError, load_registry, scope_errors
from .store import Store
from .trees import GitTree, Tree, WorkTree

MODES = ("pr", "deploy", "manual", "reconcile", "drift", "retire", "promote")
MODULE_DIR_RE = re.compile(r"^((?:[^/]+/)*modules/[^/]+)/")
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
                 artifact_digests: Optional[Dict[str, str]] = None, scope: Optional[str] = None):
        self.repo = Path(repo).resolve()
        self.env = env
        if scope not in (None, *SCOPES):
            raise SelectionError(f"unknown scope '{scope}' (expected one of {', '.join(SCOPES)})")
        self.scope = scope
        if worktree or not (self.repo / ".git").exists():
            self.tree: Tree = WorkTree(self.repo)
            self.head = None
        else:
            self.tree = GitTree(self.repo, head)
            self.head = self.tree.rev
        self.registry = load_registry(self.tree)
        problems = scope_errors(self.registry)
        if problems:
            raise SelectionError("invalid pipeline scopes:\n  " + "\n  ".join(problems))
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
        "resolve": False,
        "changed_paths": [],
        "reason": [],
        "deploy_fp": ctx.fp.deploy_fp(cid) if not c.is_docs else None,
        "validation_fp": ctx.fp.validation_fp(cid),
        "fp_parts": ctx.fp.parts(cid) if not c.is_docs else None,
        "previous_fp": None,
        "changed_parts": [],
        "layer": ctx.layer_of.get(cid, 0),
        "wave": None,
        "timeout_minutes": c.timeout_minutes,
        "contract_versions": ctx.fp.consumed_contracts(c) if not c.is_docs else {},
        "upstream": sorted(ctx.graph.upstream(cid, ctx.enabled)),
        "produces": list(c.produces),
        "scope": c.scope,
        "waiting_for": [],
    }


def _add_reason(e: dict, reason: str) -> None:
    if reason not in e["reason"]:
        e["reason"].append(reason)


def _infra_change(parts: Iterable[str]) -> bool:
    return any(p != "artifacts" for p in parts)


def _scope_filter(ctx: Context, doc: dict) -> None:
    """Restrict a selection to one pipeline scope (platform | applications).

    Applications components never plan/apply while a platform component they (transitively) consume is
    itself changed and not yet recorded as deployed: they are marked `waiting_for` and are picked up by
    the applications run that the platform pipeline triggers on success (pipeline resource trigger),
    where the contract-hash comparison re-selects exactly the consumers whose inputs changed."""
    doc["scope"] = ctx.scope
    if ctx.scope is None:
        return
    comps = doc["components"]
    pending = {cid for cid, e in comps.items()
               if e["scope"] != ctx.scope and e["plan"] and e.get("direct") and doc["mode"] not in ("drift",)}
    for cid, e in comps.items():
        if e["scope"] != ctx.scope:
            if e["plan"] or e["build"] or e["resolve"] or e["validate"]:
                e["reason"].append(f"handled by the {e['scope']} pipeline")
            e.update(plan=False, apply_candidate=False, build=False, resolve=False, validate=False, out_of_scope=True)
            continue
        if ctx.scope == "applications" and e["plan"] and doc["mode"] not in ("pr", "drift"):
            ups = ctx.graph.transitive_upstream(cid, ctx.enabled)
            waiting = sorted(u for u in ups if u in pending)
            if waiting:
                e["waiting_for"] = waiting
                e.update(plan=False, apply_candidate=False)
                _add_reason(e, "waiting for the platform pipeline to deploy: " + ", ".join(waiting))
    if ctx.scope != "platform":
        doc["modules_to_validate"] = []
    doc["retirements"] = [r for r in doc.get("retirements", []) if r.get("scope", "platform") == ctx.scope]
    # artifacts are only needed by planned roots of this scope
    for cid, e in comps.items():
        if e["kind"] == "artifact" and e["resolve"] and not e["build"]:
            if not any(comps[d]["plan"] for d, k in ctx.graph.consumers(cid).items() if k == "artifact" and d in comps):
                e["resolve"] = False


def _finish(ctx: Context, doc: dict) -> dict:
    _scope_filter(ctx, doc)
    comps = doc["components"]
    planned = [cid for cid, e in comps.items() if e["plan"]]
    waves = ctx.graph.layers(nodes=planned, enabled=ctx.enabled) if planned else []
    for i, wave in enumerate(waves):
        for cid in wave:
            comps[cid]["wave"] = i
    doc["waves"] = waves
    doc["artifacts_to_build"] = sorted(cid for cid, e in comps.items() if e["build"])
    doc["artifacts_to_resolve"] = sorted(cid for cid, e in comps.items() if e["resolve"] and not e["build"])
    doc["directly_changed"] = sorted(cid for cid, e in comps.items() if e.get("direct"))
    doc["path_owners"] = sorted(cid for cid, e in comps.items() if e["changed_paths"])
    doc["summary"] = {
        "validate": sorted(cid for cid, e in comps.items() if e["validate"]),
        "plan": sorted(planned),
        "apply_candidates": sorted(cid for cid, e in comps.items() if e["apply_candidate"]),
        "build": doc["artifacts_to_build"],
        "resolve": doc["artifacts_to_resolve"],
        "retire_scheduled": [r["component"] for r in doc.get("retirements", []) if r["status"] == "retire-scheduled"],
        "waiting": sorted(cid for cid, e in comps.items() if e.get("waiting_for")),
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
        "modules_to_validate": [],
        "unowned_paths": [],
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
            ae["resolve"] = True
            _add_reason(ae, f"required by planned {cid} (resolve existing digest; build if missing)")


# ------------------------------------------------------------------------ PR
def select_pr(repo: Path, env: str, target: str = "main", head: str = "HEAD", base: Optional[str] = None,
              scope: Optional[str] = None, worktree: bool = False) -> dict:
    """worktree=True compares the base with the uncommitted working tree (tools.changeset explain)."""
    ctx = Context(repo, env, head, worktree=worktree, scope=scope)
    doc = _base_doc(ctx, "pr")
    if base is None:
        target_ref = resolve_target_ref(ctx.repo, target)
        base = merge_base(ctx.repo, target_ref, ctx.head or "HEAD")
        doc["target"] = target_ref
    else:
        base = rev_parse(ctx.repo, base)
    doc["base"] = base
    changes = diff(ctx.repo, base, ctx.head)   # head None = working tree
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
                    comps[c.id]["direct"] = True
                    if p not in comps[c.id]["changed_paths"]:
                        comps[c.id]["changed_paths"].append(p)
            if base_registry is not None and base_fp is not None:
                for c in base_registry:
                    if c.id not in comps or p in comps[c.id]["changed_paths"]:
                        continue
                    if base_fp.owns(c, p):
                        _add_reason(comps[c.id], f"{ch.status}: {p} (owned at base)")
                        comps[c.id]["validate"] = True
                        comps[c.id]["direct"] = True
                        if p not in comps[c.id]["changed_paths"]:
                            comps[c.id]["changed_paths"].append(p)

    # 1b. changed Terraform module directories nobody consumes yet still get validated
    owned = {p for e in comps.values() for p in e["changed_paths"]}
    modules = set()
    for p in all_paths:
        m = MODULE_DIR_RE.match(p)
        if m and p not in owned and (ctx.tree.exists(p) or ctx.tree.is_dir(m.group(1))):
            modules.add(m.group(1))
    doc["unowned_paths"] = sorted(p for p in set(all_paths) - owned if not p.startswith(TOOLING_PATHS))
    doc["modules_to_validate"] = sorted(m for m in modules if ctx.tree.is_dir(m))

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
            e["direct"] = True
            e["validate"] = True
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
        rec_scope = rec.get("scope") or (ctx.registry.get(cid).scope if in_registry else
                                          ("applications" if str(rec.get("path", "")).startswith("applications/") else "platform"))
        entry = {
            "component": cid,
            "scope": rec_scope,
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
                  artifact_digests: Optional[Dict[str, str]] = None, worktree: bool = False,
                  scope: Optional[str] = None, contracts_store: Optional[Store] = None, mode: str = "deploy") -> dict:
    ctx = Context(repo, env, head, worktree=worktree, artifact_digests=artifact_digests, scope=scope)
    return _deploy(ctx, store, contracts_store, mode)


def _contract_changes(ctx: Context, doc: dict, store: Optional[Store], contracts_store: Optional[Store]) -> Set[str]:
    """Components whose materialized upstream contracts differ from the ones recorded at their last
    deployment (`contracts_sha` in the record). This is how consumers in the applications pipeline are
    re-planned after the platform pipeline changed a contract, and how out-of-band contract changes are
    caught in either pipeline."""
    changed: Set[str] = set()
    if store is None or contracts_store is None:
        return changed
    from tools.contracts.lib import ContractError
    from tools.contracts.materialize import contract_values, values_digest

    for cid, e in doc["components"].items():
        c = ctx.registry.get(cid)
        if not c.deployable or cid not in ctx.enabled or e["plan"] or (ctx.scope and c.scope != ctx.scope):
            continue
        rec = _record(store, ctx.env, cid)
        if not rec or not rec.get("contracts_sha"):
            continue
        try:
            values, _notes = contract_values(ctx.tree, ctx.registry, ctx.enabled, ctx.env, cid, contracts_store)
        except ContractError as exc:
            doc["notes"].append(f"{cid}: contracts not materializable ({str(exc).splitlines()[0]}); plan will report it")
            _plan(ctx, doc, cid, "upstream contracts unavailable", apply=True)
            changed.add(cid)
            continue
        if values_digest(values) != rec["contracts_sha"]:
            _plan(ctx, doc, cid, "upstream contract changed since the last deployment", apply=True)
            e["changed_parts"] = sorted(set(e["changed_parts"]) | {"upstream-contracts"})
            e["direct"] = True
            changed.add(cid)
    return changed


def _deploy(ctx: Context, store: Optional[Store], contracts_store: Optional[Store], mode: str = "deploy") -> dict:
    env = ctx.env
    doc = _base_doc(ctx, mode)
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
        e["direct"] = True
        if c.is_artifact:
            e["build"] = True
            continue
        _plan(ctx, doc, cid, reason, apply=True)
        if _infra_change(parts):
            infra_changed.add(cid)
    infra_changed |= _contract_changes(ctx, doc, store, contracts_store)
    for cid in sorted(infra_changed):
        for d in sorted(ctx.graph.transitive_consumers([cid], enabled=ctx.enabled)):
            if ctx.registry.get(d).deployable:
                _plan(ctx, doc, d, f"upstream {cid} changed (apply only if plan has changes)", apply=True)
    _artifacts_for_planned(ctx, doc)
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


# -------------------------------------------------------------------- MANUAL
def select_manual(repo: Path, env: str, components: List[str], with_consumers: bool = False,
                  store: Optional[Store] = None, head: str = "HEAD", worktree: bool = False,
                  scope: Optional[str] = None) -> dict:
    ctx = Context(repo, env, head, worktree=worktree, scope=scope)
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
        if ctx.scope and c.scope != ctx.scope:
            raise SelectionError(f"'{cid}' belongs to the {c.scope} pipeline, not the {ctx.scope} pipeline")
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
               worktree: bool = False, scope: Optional[str] = None) -> dict:
    assert mode in ("reconcile", "drift")
    ctx = Context(repo, env, head, worktree=worktree, scope=scope)
    doc = _base_doc(ctx, mode)
    for c in ctx.registry:
        if c.deployable and c.id in ctx.enabled:
            reason = "reconcile: plan every enabled component" if mode == "reconcile" else "drift detection (plan only)"
            _plan(ctx, doc, c.id, reason, apply=(mode == "reconcile"))
            doc["components"][c.id]["validate"] = True
            rec = _record(store, env, c.id)
            if rec:
                doc["components"][c.id]["previous_fp"] = rec.get("deploy_fp")
    _artifacts_for_planned(ctx, doc)
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


def select_retire(repo: Path, env: str, store: Optional[Store], head: str = "HEAD", worktree: bool = False,
                  scope: Optional[str] = None) -> dict:
    ctx = Context(repo, env, head, worktree=worktree, scope=scope)
    doc = _base_doc(ctx, "retire")
    if store is None:
        raise SelectionError("retire mode needs the deployment record store (--records-dir/--records-url)")
    _retirements(ctx, doc, store)
    return _finish(ctx, doc)


PROMOTION_PARTS = ("source", "tools", "registry", "artifacts")


def select_promote(repo: Path, env: str, store: Optional[Store], source_env: str, source_store: Optional[Store],
                   head: str = "HEAD", worktree: bool = False, scope: Optional[str] = None,
                   contracts_store: Optional[Store] = None) -> dict:
    """Promotion = deploy-mode selection for `env`, gated on `source_env` having successfully deployed the
    SAME code: for every enabled component of this scope that the source environment also enables, the
    source record must be `succeeded` with identical fingerprint parts source/tools/registry/artifacts
    (config and contracts are environment specific and excluded). Fails with the list of components to
    promote/deploy in the source environment first."""
    from tools.config.promotion import PromotionError, load as load_promotion

    try:
        chain = load_promotion(Path(repo))
    except PromotionError as exc:
        raise SelectionError(str(exc)) from None
    spec = chain.get(env)
    if spec is None or not spec.promote_from:
        raise SelectionError(f"environment '{env}' does not promote from another environment (environments/promotion.yaml)")
    if source_env not in ("", "auto") and source_env != spec.promote_from:
        raise SelectionError(f"'{env}' promotes from '{spec.promote_from}', not '{source_env}'")
    source_env = spec.promote_from
    if source_store is None:
        raise SelectionError("promote mode needs the source environment's record store (--source-records-url)")
    ctx = Context(repo, env, head, worktree=worktree, scope=scope)
    src_enabled, _e, _p, _n = _load_env(ctx.tree, ctx.registry, ctx.graph, source_env)
    problems, warnings = [], []
    for c in ctx.registry:
        if c.id not in ctx.enabled or not (c.deployable or c.is_artifact) or (scope and c.scope != scope):
            continue
        if c.id not in src_enabled:
            warnings.append(f"{c.id}: not enabled in '{source_env}', so it was not proven there")
            continue
        rec = source_store.get_json(f"{source_env}/{c.id}.json")
        if not rec or rec.get("status") != SUCCEEDED:
            problems.append(f"{c.id}: no successful deployment in '{source_env}'")
            continue
        mine = ctx.fp.parts(c.id)
        theirs = rec.get("fp_parts") or {}
        diff = [k for k in PROMOTION_PARTS if k in mine and theirs.get(k) != mine.get(k)]
        if diff:
            problems.append(f"{c.id}: '{source_env}' runs different {'/'.join(diff)} (deploy this commit there first)")
    if problems:
        raise SelectionError(f"cannot promote to '{env}': '{source_env}' has not successfully deployed this commit:\n  "
                             + "\n  ".join(problems))
    doc = _deploy(ctx, store, contracts_store, mode="promote")
    doc["promotion"] = {"source": source_env, "warnings": warnings}
    doc["notes"].extend(warnings)
    return doc


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
