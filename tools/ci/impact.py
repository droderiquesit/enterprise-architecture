"""Test impact selection: which suites a change needs, and why.

Inputs: a changeset selection document (tools.changeset select: changed files, per-component `validate` flag =
changed components + transitive consumers of infrastructure changes, `validation_fp`, changed shared modules).

  changed run (PR)  component:<id> for every component the selection validates; module:<dir> for changed shared
                    modules nobody consumes yet; suites.yaml suites whose `inputs` match a changed file or whose
                    `covers` intersect the validated components; the `gates` suite always. A change to
                    `global_inputs` (versions.yaml, tools/ci) selects everything.
  full run          every suite of the scope (nightly schedule, release/* branches, --all). The test result cache is
                    bypassed on full runs (results are still written), so a poisoned cache entry lives at most a day.
  deploy run (main) every suite, served from the cache where the fingerprint already passed: only what changed
                    since the last green run executes.
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional

from tools.changeset import globs
from tools.changeset.registry import Registry
from tools.changeset.trees import Tree

from .catalog import Catalog, Suite, fingerprint, module_suite


def _changed_paths(selection: dict) -> Optional[List[str]]:
    if "changed_files" not in selection:
        return None
    out = []
    for ch in selection["changed_files"]:
        out.append(ch["path"])
        if ch.get("old_path"):
            out.append(ch["old_path"])
    return sorted(set(out))


def select(catalog: Catalog, selection: dict, tree: Tree, registry: Registry, *, scope: Optional[str] = None,
           full: bool = False, module_dirs: Optional[List[str]] = None) -> Dict[str, dict]:
    """{suite id: {reasons, fingerprint, suite}} for the suites to run (cache decisions come later)."""
    changed = _changed_paths(selection)
    comps = selection.get("components") or {}
    reasons: Dict[str, List[str]] = {}

    def add(sid: str, why: str) -> None:
        reasons.setdefault(sid, []).append(why)

    full_reason = ""
    if full:
        full_reason = "full run (nightly / release / --all)"
    elif changed is None:
        full = True
        full_reason = "deploy run (no diff): everything, served from the test cache where already green"
    else:
        hits = [p for p in changed if globs.match_any(catalog.global_inputs, p)]
        if hits:
            full = True
            full_reason = f"global input changed ({hits[0]}{' ...' if len(hits) > 1 else ''})"

    validated = {cid for cid, e in comps.items() if e.get("validate")}
    for sid, s in sorted(catalog.suites.items()):
        if scope and s.scope != scope:
            continue
        if s.kind == "component":
            e = comps.get(s.component)
            if e is None or e.get("out_of_scope"):
                continue
            if full:
                add(sid, full_reason)
            elif s.component in validated:
                add(sid, "; ".join(e.get("reason") or ["selected for validation"])[:200])
            continue
        if full:
            add(sid, full_reason)
            continue
        if s.tier == "gate" and "**" in s.inputs:
            add(sid, "gate: every change")
            continue
        m = [p for p in changed if globs.match_any(s.inputs, p)]
        if m:
            add(sid, f"input changed: {m[0]}" + (f" (+{len(m) - 1})" if len(m) > 1 else ""))
        cov = sorted(set(s.covers) & validated)
        if cov:
            add(sid, f"covers selected component(s): {', '.join(cov[:4])}")
    mods = list(selection.get("modules_to_validate") or [])
    if full and module_dirs is not None:
        mods = sorted(set(mods) | set(module_dirs))
    extra_suites: Dict[str, Suite] = {}
    if not scope or scope == "platform":
        for d in mods:
            s = module_suite(d)
            extra_suites[s.id] = s
            add(s.id, full_reason if full else "shared module changed")

    def fp_component(cid: str) -> str:
        return (comps.get(cid) or {}).get("validation_fp") or ""

    out = {}
    for sid, why in sorted(reasons.items()):
        s = catalog.suites.get(sid) or extra_suites[sid]
        s.fingerprint = fingerprint(s, tree, catalog, fp_component)
        out[sid] = {"reasons": why, "suite": s}
    return out


def module_dirs(repo: Path) -> List[str]:
    from tools.validate.all_terraform import module_dirs as _md

    return _md(repo)
