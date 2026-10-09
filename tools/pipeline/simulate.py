"""Simulate a pipeline run over the generated stages using the condition evaluator.

Inputs: the generated stages document, the Select stage output variables (tools.changeset.ado),
plan exit codes per component (0 no changes, 1 error, 2 changes), optional apply failures, Build
readiness per artifact and results of the gate stages. Output: per-stage result and the set of
components that applied. Used by tests to prove end-to-end behaviour of the generated conditions
(skipped upstream, failed upstream, plan-without-changes, artifact readiness).
"""

from __future__ import annotations

from typing import Dict, Iterable, Optional, Set

from tools.changeset.registry import var_id

from .conditions import EvalContext, evaluate


def _stage_list(doc: dict) -> list[dict]:
    stages = []
    for s in doc["stages"]:
        if "stage" in s:
            stages.append(s)
        elif str(s.get("template", "")).endswith("retire.yml"):
            p = s["parameters"]
            stages.append({"stage": "Retire", "dependsOn": p["dependsOn"], "condition": p["condition"]})
    return stages


def simulate(doc: dict, select_outputs: Dict[str, str], plan_exit: Dict[str, int],
             apply_fail: Iterable[str] = (), build_ready: Optional[Set[str]] = None,
             gate_results: Optional[Dict[str, str]] = None, run_canceled: bool = False) -> dict:
    gate_results = {"Select": "Succeeded", "Validate": "Succeeded", "Security": "Succeeded", **(gate_results or {})}
    results: Dict[str, str] = dict(gate_results)
    outputs: Dict[str, Dict[str, str]] = {
        "Select": {f"select.detect.{k}": v for k, v in select_outputs.items()},
        "Validate": {}, "Security": {},
    }
    applied, planned = [], []
    apply_fail = set(apply_fail)
    pending = _stage_list(doc)
    done = set(results)
    while pending:
        progressed = False
        for st in list(pending):
            deps = st.get("dependsOn") or []
            deps = [deps] if isinstance(deps, str) else deps
            if not all(d in done for d in deps):
                continue
            ctx = EvalContext(dependencies={d: {"result": results[d], "outputs": outputs.get(d, {})} for d in deps},
                              run_canceled=run_canceled)
            name = st["stage"]
            if not evaluate(st["condition"], ctx):
                results[name] = "Skipped"
            elif name == "Build":
                ready = build_ready
                if ready is None:
                    ready = {k[len("build_"):] for k, v in select_outputs.items() if k.startswith("build_") and v == "true"}
                outputs["Build"] = {f"B_{a}.ready.ready": "true" for a in ready}
                results[name] = "Succeeded"
            elif name.startswith("C_"):
                cid_var = name[2:]
                cid = next((c for c in plan_exit if var_id(c) == cid_var), None)
                code = plan_exit.get(cid, 0) if cid else 0
                planned.append(cid or cid_var)
                if code == 1:
                    results[name] = "Failed"
                elif code == 2 and select_outputs.get(f"apply_{cid_var}") == "true":
                    if cid in apply_fail:
                        results[name] = "Failed"
                    else:
                        results[name] = "Succeeded"
                        applied.append(cid)
                else:
                    results[name] = "Succeeded"
            else:
                results[name] = "Succeeded"
            done.add(name)
            pending.remove(st)
            progressed = True
        if not progressed:
            raise RuntimeError("stage graph cannot progress: " + ", ".join(s["stage"] for s in pending))
    return {"results": results, "applied": sorted(applied), "planned": sorted(p for p in planned if p)}
