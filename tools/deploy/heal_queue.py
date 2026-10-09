#!/usr/bin/env python3
"""Fan the scheduled heal run out to promoted environments (test, prod).

    python3 tools/deploy/heal_queue.py [--dry-run] [--force] [--hour 6]

Azure DevOps scheduled runs always use the default parameter values (environment dev), so the dev heal schedule
queues heal runs for the later environments of the promotion chain itself, via the REST API with System.AccessToken:
  * only environments with self_healing.enabled whose heal_interval_hours divides the current UTC hour (or --force);
  * at the commit that environment last ran (latest build of THIS pipeline tagged env-<env>: Builds - List
    tagFilters), so heal never brings new code into test/prod - select_heal additionally refuses any component whose
    code differs from the failed promotion;
  * skipped when a run for that environment is already queued / running (no pile-up).
Queued runs are ordinary runs: their apply stages stop at the lab-<env> approval (approvers are notified by Azure
DevOps), nothing is bypassed. Needs "Queue builds" for the project build service identity on both pipelines.
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
from typing import Callable, List, Optional

import yaml

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

Http = Callable[[str, str, Optional[dict]], Optional[dict]]


def _http(method: str, url: str, body: Optional[dict]) -> Optional[dict]:
    token = os.environ.get("SYSTEM_ACCESSTOKEN", "")
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode() or "{}")
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        print(f"##vso[task.logissue type=warning]heal fan-out: {method} {url.split('?')[0]} failed: {exc}")
        return None


def targets(repo: Path, hour: int, force: bool = False) -> List[str]:
    from tools.config.promotion import load as load_promotion

    out = []
    for name, spec in load_promotion(repo).items():
        if not spec.promote_from:
            continue
        env_doc = yaml.safe_load((repo / f"environments/{name}/environment.yaml").read_text()) or {}
        sh = env_doc.get("self_healing") or {}
        if not sh.get("enabled"):
            continue
        interval = int(sh.get("heal_interval_hours", 6) or 6)
        if force or hour % interval == 0:
            out.append(name)
    return out


def fan_out(envs: List[str], *, base: str, project: str, definition: str, http: Http = _http,
            dry_run: bool = False) -> List[dict]:
    api = f"{base.rstrip('/')}/{urllib.parse.quote(project)}/_apis"
    results = []
    for env in envs:
        tag = urllib.parse.quote(f"env-{env}")
        active = http("GET", f"{api}/build/builds?definitions={definition}&tagFilters={tag}"
                             f"&statusFilter=inProgress,notStarted&api-version=7.1", None) or {}
        if active.get("count"):
            results.append({"env": env, "action": "skipped", "reason": "a run for this environment is already active"})
            continue
        last = http("GET", f"{api}/build/builds?definitions={definition}&tagFilters={tag}"
                           f"&queryOrder=finishTimeDescending&$top=1&api-version=7.1", None) or {}
        builds = last.get("value") or []
        if not builds:
            results.append({"env": env, "action": "skipped", "reason": "this environment never ran"})
            continue
        b = builds[0]
        body = {"resources": {"repositories": {"self": {"refName": b.get("sourceBranch") or "refs/heads/main",
                                                         "version": b.get("sourceVersion")}}},
                "templateParameters": {"environment": env, "mode": "heal"}}
        if dry_run:
            results.append({"env": env, "action": "would-queue", "commit": b.get("sourceVersion")})
            continue
        run = http("POST", f"{api}/pipelines/{definition}/runs?api-version=7.1", body)
        results.append({"env": env, "action": "queued" if run else "failed", "commit": b.get("sourceVersion"),
                        "run_id": (run or {}).get("id")})
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="ignore heal_interval_hours")
    ap.add_argument("--hour", type=int, default=dt.datetime.now(dt.timezone.utc).hour)
    args = ap.parse_args(argv)
    envs = targets(REPO, args.hour, args.force)
    base, project = os.environ.get("SYSTEM_COLLECTIONURI", ""), os.environ.get("SYSTEM_TEAMPROJECT", "")
    definition = os.environ.get("SYSTEM_DEFINITIONID", "")
    if not envs:
        print(f"heal fan-out: no promoted environment due at {args.hour:02d}:00 UTC")
        return 0
    if not (base and project and definition and os.environ.get("SYSTEM_ACCESSTOKEN")):
        print(f"heal fan-out: due {envs}, but no Azure DevOps context (SYSTEM_COLLECTIONURI/TEAMPROJECT/DEFINITIONID/ACCESSTOKEN)")
        return 0
    for r in fan_out(envs, base=base, project=project, definition=definition, dry_run=args.dry_run):
        print(f"heal fan-out: {r}")
    return 0  # fan-out is best effort: never fails the dev heal run


if __name__ == "__main__":
    sys.exit(main())
