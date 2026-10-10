"""Speed visibility: per-run timing report (evidence JSON + markdown for ##vso[task.uploadsummary]).

Inputs: the CI plan (selected / cached suites, legs, estimates), the result files of every leg (ci-results.json),
optionally the Azure DevOps timeline (tools/report/pr_budget.py). Output: wall time, critical path (stages, and the
slowest leg = the Validate critical path), slowest units, cache hit rate and cached-test skips, legs vs estimates,
budget verdict (docs-only <= 2 min, single-service <= 10 min, otherwise the PR budget).
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import List, Optional

BUDGETS = {"docs-only": 2, "single-component": 10, "default": 20}


def classify_change(plan: dict) -> str:
    run = [s for s, e in plan.get("suites", {}).items() if e.get("status") == "run" and e.get("tier") != "gate"]
    if run and all(s in ("docs-links", "component:docs") for s in run):
        return "docs-only"
    comps = {s for s in run if s.startswith("component:")}
    if not run or (len(comps) <= 1 and len(run) <= 3):
        return "single-component" if run else "docs-only"
    return "default"


def _ts(v: Optional[str]) -> Optional[dt.datetime]:
    from tools.report.pr_budget import _ts as parse

    return parse(v)


def critical_path(timeline: dict) -> List[dict]:
    """Chain of stages ending at the last finished one; each predecessor = the stage that finished last before
    the successor started (stage dependencies are not in the timeline, start/finish times are)."""
    stages = []
    for r in timeline.get("records") or []:
        if r.get("type") == "Stage" and r.get("startTime") and r.get("finishTime"):
            stages.append({"name": r.get("name"), "start": _ts(r["startTime"]), "finish": _ts(r["finishTime"])})
    if not stages:
        return []
    cur = max(stages, key=lambda s: s["finish"])
    path = [cur]
    while True:
        prev = [s for s in stages if s["finish"] <= cur["start"] and s is not cur]
        if not prev:
            break
        cur = max(prev, key=lambda s: s["finish"])
        path.append(cur)
    return [{"stage": s["name"], "minutes": round((s["finish"] - s["start"]).total_seconds() / 60, 2)} for s in reversed(path)]


def build(plan: dict, leg_results: List[dict], timeline: Optional[dict] = None, budget_minutes: Optional[float] = None) -> dict:
    units = [r for lr in leg_results for r in lr.get("results", [])]
    planned = plan.get("suites", {})
    cached = sorted(s for s, e in planned.items() if e.get("status") == "cached")
    ran = sorted({u["suite"] for u in units if u["status"] in ("passed", "failed")})
    eligible = [s for s, e in planned.items() if e.get("cacheable", True)]
    legs = []
    for lr in leg_results:
        secs = lr.get("seconds") or sum(r.get("seconds", 0) for r in lr.get("results", []))
        est = next((lg.get("estimate_seconds") for lg in plan.get("legs", []) if lg["name"] == lr.get("leg")), None)
        legs.append({"leg": lr.get("leg"), "seconds": round(secs, 1), "estimate_seconds": est,
                     "units": len(lr.get("results", [])), "failed": sum(r["status"] == "failed" for r in lr.get("results", []))})
    kind = classify_change(plan)
    budget = budget_minutes if budget_minutes is not None else BUDGETS[kind]
    doc = {
        "change_class": kind, "budget_minutes": budget,
        "suites_selected": len(planned), "suites_cached": len(cached), "suites_run": len(ran),
        "cache_hit_rate": round(len(cached) / len(eligible), 3) if eligible else 0.0,
        "cached_suites": cached,
        "failed_units": sorted(u["unit"] for u in units if u["status"] == "failed"),
        "skipped_units": sorted(u["unit"] for u in units if u["status"] == "skipped"),
        "slowest_units": [{"unit": u["unit"], "seconds": u["seconds"], "estimate": u.get("estimate")}
                          for u in sorted(units, key=lambda u: -u.get("seconds", 0))[:10]],
        "legs": sorted(legs, key=lambda x: -x["seconds"]),
        "validate_critical_leg": max(legs, key=lambda x: x["seconds"])["leg"] if legs else None,
        "validate_seconds": round(max((x["seconds"] for x in legs), default=0.0), 1),
    }
    if timeline:
        from tools.report.pr_budget import summarize

        tl = summarize(timeline, budget)
        doc["wall_minutes"] = tl["wall_minutes"]
        doc["slowest_jobs"] = tl["slowest_jobs"]
        doc["critical_path"] = critical_path(timeline)
        doc["over_budget"] = tl["wall_minutes"] > budget
    else:
        doc["over_budget"] = doc["validate_seconds"] / 60 > budget
    return doc


def markdown(doc: dict) -> str:
    lines = [f"## CI speed: {doc['change_class']} change (budget {doc['budget_minutes']} min) - "
             f"{'OVER BUDGET' if doc['over_budget'] else 'within budget'}", "",
             f"* suites selected {doc['suites_selected']}, run {doc['suites_run']}, served from the test cache "
             f"{doc['suites_cached']} (hit rate {doc['cache_hit_rate']:.0%})",
             f"* Validate critical leg: {doc['validate_critical_leg']} ({doc['validate_seconds']} s)"]
    if doc.get("wall_minutes") is not None:
        lines.append(f"* wall time {doc['wall_minutes']} min; critical path: "
                     + " -> ".join(f"{s['stage']} ({s['minutes']} min)" for s in doc.get("critical_path", [])))
    lines += ["", "| slowest units | s | estimate |", "|---|---|---|"]
    lines += [f"| {u['unit']} | {u['seconds']} | {u.get('estimate')} |" for u in doc["slowest_units"]]
    lines += ["", "| leg | s | estimate | units | failed |", "|---|---|---|---|---|"]
    lines += [f"| {lg['leg']} | {lg['seconds']} | {lg['estimate_seconds']} | {lg['units']} | {lg['failed']} |" for lg in doc["legs"]]
    return "\n".join(lines) + "\n"


def load_leg_results(results_dir: Path) -> List[dict]:
    """One result document per leg; a retried leg (ci-<leg>-<attempt>) counts with its latest attempt."""
    by_leg = {}
    for f in sorted(Path(results_dir).glob("**/ci-results.json"), key=lambda p: (len(str(p)), str(p))):
        try:
            doc = json.loads(f.read_text())
        except ValueError:
            continue
        by_leg[doc.get("leg") or str(f)] = doc
    return [by_leg[k] for k in sorted(by_leg)]
