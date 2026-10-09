"""Azure DevOps logging-command output for a selection document.

Output variables (step name `detect` in job `select` of stage `Select`):
  sel_<id>         'true' when the component stage must run (plan); always 'false' for PR builds
  apply_<id>       'true' when the stage may apply (still gated by the plan's has_changes)
  build_<id>       'true' when the artifact must be resolved (existing digest for its source
                   fingerprint) or built
  validate_matrix  JSON matrix for the Validate stage; validate_count its size
  any_deploy, any_build, has_retirements, mode, selection_summary (compact JSON)
Component ids use '_' instead of '-' (ADO names allow letters, digits and '_').
"""

from __future__ import annotations

import json
import re
from typing import Dict, List

from .registry import Registry, var_id


def _bool(v: bool) -> str:
    return "true" if v else "false"


def validate_matrix(doc: dict, registry: Registry) -> Dict[str, dict]:
    matrix = {}
    for cid, e in sorted(doc["components"].items()):
        if not e["validate"]:
            continue
        c = registry.get(cid)
        matrix[var_id(cid)] = {"component": cid, "kind": c.kind, "componentPath": c.path}
    for mod in doc.get("modules_to_validate", []):
        key = "module_" + re.sub(r"[^A-Za-z0-9_]", "_", mod)
        matrix[key] = {"component": f"module:{mod}", "kind": "module", "componentPath": mod}
    return matrix


def output_variables(doc: dict, registry: Registry) -> Dict[str, str]:
    pr = doc["mode"] == "pr"
    out: Dict[str, str] = {}
    for c in registry:
        if c.pipeline == "manual" or c.is_docs:
            continue
        e = doc["components"].get(c.id) or {}
        if c.is_artifact:
            out[f"build_{c.var_id}"] = _bool(bool(e.get("build") or e.get("resolve")) and not pr)
        else:
            out[f"sel_{c.var_id}"] = _bool(bool(e.get("plan")) and not pr)
            out[f"apply_{c.var_id}"] = _bool(bool(e.get("apply_candidate")) and not pr)
    matrix = validate_matrix(doc, registry)
    out["validate_matrix"] = json.dumps(matrix, separators=(",", ":"), sort_keys=True)
    out["validate_count"] = str(len(matrix))
    out["any_deploy"] = _bool(any(v == "true" for k, v in out.items() if k.startswith("sel_")))
    out["any_build"] = _bool(any(v == "true" for k, v in out.items() if k.startswith("build_")))
    out["has_retirements"] = _bool(any(r["status"] == "retire-scheduled" for r in doc.get("retirements", [])) and not pr)
    out["mode"] = doc["mode"]
    out["selection_summary"] = json.dumps(doc.get("summary", {}), separators=(",", ":"), sort_keys=True)
    return out


def logging_commands(doc: dict, registry: Registry) -> List[str]:
    lines = []
    for name, value in output_variables(doc, registry).items():
        if "\n" in value or "\r" in value:
            raise ValueError(f"output variable {name} must be single-line")
        lines.append(f"##vso[task.setvariable variable={name};isOutput=true]{value}")
    for r in doc.get("retirements", []):
        if r["status"] in ("retire-pending", "retire-blocked"):
            lines.append(f"##vso[task.logissue type=warning]{r['component']}: {r['status']} - {r['reason']}")
    return lines
