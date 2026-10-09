#!/usr/bin/env python3
"""Drift auto-remediation guard (drift-mode runs only).

    python3 tools/deploy/remediate.py check --selection selection.json --component X --plan-json plan.json [--out r.json]

Prints `remediate=true|false|refused|n/a` as the LAST line (tf-plan.sh reads it):
  n/a    not a drift run, or the component is not marked `remediate: additive-only` by the selection
         (registry drift.auto_remediate AND environments/<env> self_healing.drift_auto_remediate)
  true   the drift plan only creates / updates resources -> the apply stage re-applies the code's desired state
  false  no drift
  refused the plan would delete or replace something -> never auto-applied; reported (and alerted) instead
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List, Tuple

DESTRUCTIVE = {"delete"}


def assess(plan_json: dict) -> Tuple[bool, List[str], List[str]]:
    """(additive_only, destructive changes, additive changes)."""
    bad, ok = [], []
    for rc in plan_json.get("resource_changes", []) or []:
        if rc.get("mode") == "data":
            continue
        actions = set((rc.get("change") or {}).get("actions") or [])
        if actions <= {"no-op", "read"}:
            continue
        label = f"{rc.get('address')}: {'/'.join(sorted(actions))}"
        (bad if actions & DESTRUCTIVE else ok).append(label)
    return not bad, bad, ok


def decide(selection: dict, component: str, plan_json: dict) -> dict:
    entry = (selection.get("components") or {}).get(component) or {}
    if selection.get("mode") != "drift" or entry.get("remediate") != "additive-only":
        return {"component": component, "remediate": "n/a"}
    additive, bad, ok = assess(plan_json)
    return {"component": component, "remediate": "refused" if bad else "true" if ok else "false",
            "destructive": bad, "additive": ok,
            "reason": ("additive-only drift: re-applying" if additive and ok else
                       "no drift" if not ok and not bad else "plan deletes/replaces resources: report only")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("check",))
    ap.add_argument("--selection", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--plan-json", required=True)
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    sel = json.loads(Path(args.selection).read_text()) if Path(args.selection).exists() else {}
    res = decide(sel, args.component, json.loads(Path(args.plan_json).read_text()))
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(res, indent=2))
    if res["remediate"] == "refused":
        print(f"##vso[task.logissue type=warning]{args.component}: drift not auto-remediated - "
              f"{len(res['destructive'])} delete/replace change(s): {'; '.join(res['destructive'][:5])}")
    print(f"remediate={res['remediate']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
