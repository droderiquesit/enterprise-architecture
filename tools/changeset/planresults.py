"""Turn plan outcomes into the final apply decision (mirrors the pipeline's Apply job condition).

Terraform `plan -detailed-exitcode`: 0 = no changes, 1 = error, 2 = changes present.
A component applies when it was planned, is an apply candidate, and its plan exit code is 2.
"""

from __future__ import annotations

from typing import Dict, List


def apply_set(selection: dict, plan_exit_codes: Dict[str, int]) -> Dict[str, List[str]]:
    applied, unchanged, failed, not_planned = [], [], [], []
    for cid, e in sorted(selection["components"].items()):
        if not e.get("plan"):
            continue
        code = plan_exit_codes.get(cid)
        if code is None:
            not_planned.append(cid)
        elif code == 1:
            failed.append(cid)
        elif code == 2 and e.get("apply_candidate"):
            applied.append(cid)
        else:
            unchanged.append(cid)
    return {"apply": applied, "no_changes_or_plan_only": unchanged, "plan_failed": failed, "not_planned": not_planned}
