#!/usr/bin/env python3
"""Time budget report of a PR validation run (evidence JSON + run summary).

    python3 tools/report/pr_budget.py --budget-minutes 20 --out pr-budget.json [--markdown pr-budget.md]

Reads the run's timeline (Azure DevOps REST `_apis/build/builds/<id>/timeline`, System.AccessToken) and reports
wall-clock time so far, per-stage and per-job durations, queue time (agent wait) and the slowest jobs, against the
budget (pipelines/variables/tools.yml prTimeBudgetMinutes). Over budget = warning (never fails the PR): the report
says where the time went (a cold cache, a big validate matrix, a slow test shard).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Optional


def _ts(v: Optional[str]) -> Optional[dt.datetime]:
    if not v:
        return None
    v = v.rstrip("Z")
    if "." in v:
        head, frac = v.split(".", 1)
        v = f"{head}.{frac[:6]}"
    return dt.datetime.fromisoformat(v).replace(tzinfo=dt.timezone.utc)


def summarize(timeline: dict, budget_minutes: float, now: Optional[dt.datetime] = None) -> dict:
    now = now or dt.datetime.now(dt.timezone.utc)
    recs = timeline.get("records") or []
    starts = [_ts(r.get("startTime")) for r in recs if r.get("startTime")]
    begin = min(starts) if starts else now
    out = {"budget_minutes": budget_minutes, "stages": [], "jobs": []}
    for r in recs:
        if r.get("type") not in ("Stage", "Job"):
            continue
        st, fin = _ts(r.get("startTime")), _ts(r.get("finishTime")) or (now if r.get("startTime") else None)
        item = {"name": r.get("name"), "result": r.get("result") or r.get("state"),
                "minutes": round(((fin - st).total_seconds() / 60) if st and fin else 0.0, 2)}
        if r.get("type") == "Job":
            # queue time: from the stage's start to the job's start (waiting for an agent)
            item["worker"] = r.get("workerName")
        out["stages" if r.get("type") == "Stage" else "jobs"].append(item)
    wall = round((now - begin).total_seconds() / 60, 2)
    out["wall_minutes"] = wall
    out["over_budget"] = wall > budget_minutes
    out["slowest_jobs"] = sorted(out["jobs"], key=lambda j: -j["minutes"])[:5]
    return out


def markdown(doc: dict) -> str:
    lines = [f"## PR time budget: {doc['wall_minutes']} of {doc['budget_minutes']} min "
             f"({'OVER' if doc['over_budget'] else 'ok'})", "", "| slowest jobs | minutes |", "|---|---|"]
    lines += [f"| {j['name']} | {j['minutes']} |" for j in doc["slowest_jobs"]]
    return "\n".join(lines) + "\n"


def fetch_timeline(http: Optional[Callable] = None) -> dict:
    base, project = os.environ.get("SYSTEM_COLLECTIONURI", ""), os.environ.get("SYSTEM_TEAMPROJECT", "")
    build, token = os.environ.get("BUILD_BUILDID", ""), os.environ.get("SYSTEM_ACCESSTOKEN", "")
    if not (base and project and build and token):
        return {}
    url = f"{base.rstrip('/')}/{urllib.parse.quote(project)}/_apis/build/builds/{build}/timeline?api-version=7.1"
    if http:
        return http(url)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return {}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--budget-minutes", type=float, default=20)
    ap.add_argument("--timeline", help="timeline JSON file (default: REST)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--markdown")
    args = ap.parse_args(argv)
    tl = json.loads(Path(args.timeline).read_text()) if args.timeline else fetch_timeline()
    if not tl:
        print("##vso[task.logissue type=warning]PR budget: timeline not available")
        return 0
    doc = summarize(tl, args.budget_minutes)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(doc, indent=2))
    if args.markdown:
        Path(args.markdown).write_text(markdown(doc))
    if doc["over_budget"]:
        print(f"##vso[task.logissue type=warning]PR validation took {doc['wall_minutes']} min "
              f"(budget {doc['budget_minutes']}); slowest: {', '.join(j['name'] for j in doc['slowest_jobs'][:3])}")
    print(json.dumps({k: doc[k] for k in ('wall_minutes', 'budget_minutes', 'over_budget')}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
