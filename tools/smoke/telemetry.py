#!/usr/bin/env python3
"""Telemetry verification adapter: runs the observability package's journey verifier for the deployments of this
run and maps its single journey result onto per-component outcomes (the input of `record.py verify`).

    python3 tools/smoke/telemetry.py args    --env dev --selection selection.json            # print verifier argv (JSON)
    python3 tools/smoke/telemetry.py results --env dev --selection selection.json \
        --evidence telemetry-evidence.json --exit-code <verifier rc> --out telemetry-results.json

The verifier (observability/tools/verify/telemetry_verify.py, owned by the observability team) checks ONE journey
(RUM -> APM -> logs, duplicates, tags); its interface is --journey-service (repeatable, entry first),
--frontend-service, --max-wait, --evidence. The journey comes from environments/<env>/environment.yaml
`datadog.telemetry_verification` (defaults below). A failed journey marks every application deployment component
selected in this run as verification=failed (heal mode re-runs them); a verifier usage/auth error (exit 2/3) is a
pipeline problem, not an application one, and records nothing ("not-run").
Output: {"env", "result": pass|fail|not-run, "status": passed|failed|not-run (tools/report/report.py), "components": {<id>: {"status": "passed"|"failed"}}}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List

import yaml

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.smoke.smoke import select_components  # noqa: E402

VERIFIER = "observability/tools/verify/telemetry_verify.py"
DEFAULTS = {"journey_services": ["hello-bff", "hello-orders-api", "hello-catalog-api"],
            "frontend_service": "hello-frontend", "max_wait_seconds": 600}


def settings(env: str, repo: Path = REPO) -> dict:
    p = repo / f"environments/{env}/environment.yaml"
    doc = yaml.safe_load(p.read_text()) if p.exists() else {}
    cfg = dict(DEFAULTS)
    cfg.update(((doc or {}).get("datadog") or {}).get("telemetry_verification") or {})
    return cfg


def verifier_args(env: str, site: str, evidence: str, repo: Path = REPO) -> List[str]:
    cfg = settings(env, repo)
    argv = [VERIFIER, "--env", env, "--site", site, "--max-wait", str(cfg["max_wait_seconds"]), "--evidence", evidence]
    for svc in cfg["journey_services"]:
        argv += ["--journey-service", svc]
    if cfg.get("frontend_service"):
        argv += ["--frontend-service", cfg["frontend_service"]]
    return argv


def results(env: str, selection: dict, evidence: dict, exit_code: int) -> dict:
    deployed = select_components(selection, [])
    if exit_code in (2, 3) or not evidence:
        return {"env": env, "result": "not-run", "status": "not-run", "components": {},
                "reason": f"verifier exit {exit_code} (configuration / credentials) - nothing recorded"}
    result = "pass" if exit_code == 0 and evidence.get("result") == "pass" else "fail"
    status = "passed" if result == "pass" else "failed"
    failed_checks = [c.get("name") for c in evidence.get("checks") or [] if c.get("status") == "fail"]
    return {"env": env, "result": result, "status": status, "failed_checks": failed_checks,
            "components": {cid: {"status": status, "source": "telemetry"} for cid in deployed}}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("args", "results"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--selection", required=True)
    ap.add_argument("--site", default="datadoghq.com")
    ap.add_argument("--evidence", default="telemetry-evidence.json")
    ap.add_argument("--exit-code", type=int, default=0)
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    selection = json.loads(Path(args.selection).read_text())
    if args.op == "args":
        if not select_components(selection, []):
            print("[]")       # no application deployment in this run: nothing to verify
            return 0
        print(json.dumps(verifier_args(args.env, args.site, args.evidence)))
        return 0
    ev_path = Path(args.evidence)
    evidence = json.loads(ev_path.read_text()) if ev_path.exists() else {}
    doc = results(args.env, selection, evidence, args.exit_code)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print(f"telemetry verification: {doc['result']} ({len(doc['components'])} component(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
