#!/usr/bin/env python3
"""Deployment report + evidence JSON, and drift report.

    python3 tools/report/report.py deployment --run-dir <downloaded artifacts> --records <store> \
        --env dev --run-id 123 --commit <sha> --out report.md --evidence evidence.json
    python3 tools/report/report.py drift --run-dir <downloaded artifacts> --out drift.md --json drift.json [--ado]

--run-dir layout (DownloadPipelineArtifact of the current run): selection/selection.json,
plan-<component>-<attempt>/{summary.json,manifest.json}, smoke-*/smoke-results.json,
telemetry-*/telemetry-results.json.

Component status (ADR §11 vocabulary, per this run's evidence only):
  verified   applied in this run, smoke passed and telemetry verification passed
  deployed   applied in this run (record succeeded with this run id)
  unchanged  planned, no changes
  planned    planned only (drift / dry run / plan-only upstream)
  failed     plan or apply failed (record status failed/partial/canceled, or no plan output)
  skipped    selected but not run (blocked by an upstream failure)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import open_store  # noqa: E402


def _latest(run_dir: Path, pattern: str) -> dict:
    """{component: parsed json} keeping the highest job attempt."""
    out: dict = {}
    best: dict = {}
    for d in run_dir.glob(pattern):
        m = re.match(r"plan-(.+)-(\d+)$", d.name)
        if not m:
            continue
        cid, attempt = m.group(1), int(m.group(2))
        if attempt < best.get(cid, -1):
            continue
        best[cid] = attempt
        item = {}
        for name in ("summary.json", "manifest.json"):
            f = d / name
            if f.exists():
                item[name.split(".")[0]] = json.loads(f.read_text())
        out[cid] = item
    return out


def _first_json(run_dir: Path, pattern: str):
    files = sorted(run_dir.glob(pattern))
    return json.loads(files[-1].read_text()) if files else None


def load_run(run_dir: Path) -> dict:
    sel_file = run_dir / "selection" / "selection.json"
    return {
        "selection": json.loads(sel_file.read_text()) if sel_file.exists() else {"components": {}, "mode": "unknown"},
        "plans": _latest(run_dir, "plan-*"),
        "smoke": _first_json(run_dir, "smoke-*/smoke-results.json"),
        "telemetry": _first_json(run_dir, "telemetry-*/telemetry-results.json"),
    }


def component_status(cid: str, plan: dict | None, record: dict | None, run_id: str, smoke: dict | None,
                     telemetry: dict | None) -> str:
    if record and str(record.get("run_id")) == str(run_id):
        if record.get("status") != "succeeded":
            return "failed"
        applied = bool((plan or {}).get("manifest", {}).get("has_changes"))
        if not applied:
            return "unchanged"
        smoke_ok = (smoke or {}).get("components", {}).get(cid, {}).get("status") == "passed"
        tel_ok = (telemetry or {}).get("status") == "passed" or (telemetry or {}).get("components", {}).get(cid, {}).get("status") == "passed"
        return "verified" if smoke_ok and tel_ok else "deployed"
    if plan is None:
        return "skipped"
    if plan.get("manifest") is None:
        return "failed"
    return "planned" if plan["manifest"].get("has_changes") else "unchanged"


def cmd_deployment(args) -> int:
    run = load_run(Path(args.run_dir))
    sel = run["selection"]
    records = open_store(args.records) if args.records else None
    comps = {}
    for cid, e in sorted(sel.get("components", {}).items()):
        if not (e.get("plan") or e.get("build") or e.get("resolve")):
            continue
        rec = records.get_json(f"{args.env}/{cid}.json") if records else None
        plan = run["plans"].get(cid)
        status = (("built" if e.get("build") else "resolved") if e.get("kind") == "artifact"
                  else component_status(cid, plan, rec, args.run_id, run["smoke"], run["telemetry"]))
        comps[cid] = {
            "kind": e.get("kind"), "wave": e.get("wave"), "reason": e.get("reason"), "status": status,
            "deploy_fp": e.get("deploy_fp"), "previous_fp": e.get("previous_fp"),
            "plan": (plan or {}).get("summary", {}).get("counts"),
            "violations": (plan or {}).get("summary", {}).get("violations"),
            "cost_flags": (plan or {}).get("summary", {}).get("cost_flags"),
            "record": {k: (rec or {}).get(k) for k in ("status", "run_id", "commit", "finished_at")} if rec else None,
            "smoke": ((run["smoke"] or {}).get("components") or {}).get(cid, {}).get("status"),
        }
    evidence = {
        "schema_version": 1, "environment": args.env, "run_id": args.run_id, "commit": args.commit,
        "mode": sel.get("mode"), "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "components": comps, "retirements": sel.get("retirements", []),
        "telemetry": (run["telemetry"] or {}).get("status", "not-run"),
    }
    lines = [f"# Deployment report - {args.env} - run {args.run_id}", "",
             f"- mode: `{sel.get('mode')}`  commit: `{args.commit}`", f"- waves: {sel.get('waves')}", "",
             "| component | kind | wave | status | plan | reason |", "|---|---|---|---|---|---|"]
    for cid, c in comps.items():
        counts = ", ".join(f"{k}:{v}" for k, v in sorted((c["plan"] or {}).items())) or "-"
        lines.append(f"| {cid} | {c['kind']} | {c['wave'] if c['wave'] is not None else '-'} | **{c['status']}** | {counts} | "
                     f"{'; '.join(c['reason'] or [])} |")
    if sel.get("retirements"):
        lines += ["", "## Retirements", "", "| component | status | reason |", "|---|---|---|"]
        lines += [f"| {r['component']} | {r['status']} | {r['reason']} |" for r in sel["retirements"]]
    flagged = {cid: c for cid, c in comps.items() if c.get("cost_flags")}
    if flagged:
        lines += ["", "## Cost-relevant changes", ""]
        for cid, c in flagged.items():
            lines += [f"- {cid}: `{f['address']}` {f['reason']}" for f in c["cost_flags"]]
    lines += ["", "Status vocabulary: ADR-0001 §11. `deployed`/`verified` are claimed only for components whose",
              "deployment record carries this run id."]
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(lines) + "\n")
    Path(args.evidence).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print("\n".join(lines))
    return 0


def cmd_drift(args) -> int:
    run = load_run(Path(args.run_dir))
    drift = {}
    for cid, p in sorted(run["plans"].items()):
        s = p.get("summary") or {}
        if s.get("has_changes"):
            drift[cid] = s.get("counts")
    lines = ["# Drift report", ""]
    lines += [f"- **{cid}**: {counts}" for cid, counts in drift.items()] or ["No drift: every planned component matches its code."]
    Path(args.out).write_text("\n".join(lines) + "\n")
    if args.json:
        Path(args.json).write_text(json.dumps({"drift": drift, "planned": sorted(run["plans"])}, indent=2) + "\n")
    print("\n".join(lines))
    if args.ado and drift:
        for cid in drift:
            print(f"##vso[task.logissue type=warning]drift detected in {cid}")
        print("##vso[task.complete result=SucceededWithIssues;]drift detected")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("deployment")
    d.add_argument("--run-dir", required=True)
    d.add_argument("--records")
    d.add_argument("--env", required=True)
    d.add_argument("--run-id", required=True)
    d.add_argument("--commit", default="unknown")
    d.add_argument("--out", required=True)
    d.add_argument("--evidence", required=True)
    d.set_defaults(func=cmd_deployment)
    r = sub.add_parser("drift")
    r.add_argument("--run-dir", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--json")
    r.add_argument("--ado", action="store_true")
    r.set_defaults(func=cmd_drift)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
