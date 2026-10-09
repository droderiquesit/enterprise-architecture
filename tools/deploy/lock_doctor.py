#!/usr/bin/env python3
"""Stale Terraform state-lock recovery (azurerm backend, blob lease on <env>/<id>.tfstate).

    python3 tools/deploy/lock_doctor.py claim   --env dev --component X        # job start: who holds the lock
    python3 tools/deploy/lock_doctor.py release --env dev --component X        # job end
    python3 tools/deploy/lock_doctor.py recover --env dev --component X --root <dir> --error-file <terraform output>
    python3 tools/deploy/lock_doctor.py inspect --env dev --component X

Every plan/apply job writes a *holder claim* `<env>/_locks/<component>/<build>-<job>-<attempt>.json` in the
deployments container ({build_id, job_name, job_attempt, stage, started_at}) and deletes it when it ends. When Terraform reports the state lock as held:
  * the holder build is looked up with the Azure DevOps REST API (System.AccessToken,
    _apis/build/builds/<id>); while it is notStarted / inProgress / cancelling / postponed the doctor
    WAITS (backoff, bounded by --max-wait-minutes) - a lock of a running build is never broken;
  * a holder that is completed (succeeded / failed / canceled), or a previous attempt of the current job,
    whose lock is older than --min-age-minutes is stale: the lock is released with
    `terraform force-unlock -force <ID>` (or `az storage blob lease break --auth-mode login`) and an audit
    record `<env>/_audit/lock-recovery-<component>-<ts>.json` is written;
  * without a claim the lock is broken only when older than --hard-max-minutes (default 400, longer than
    any job timeout of these pipelines); an unknown holder status never leads to a break before that.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import Store, open_store  # noqa: E402

RUNNING = {"notstarted", "inprogress", "cancelling", "postponed"}


@dataclass
class LockInfo:
    id: str = ""
    path: str = ""
    who: str = ""
    operation: str = ""
    created: Optional[dt.datetime] = None


def parse_lock_info(text: str) -> LockInfo:
    def field(name):
        m = re.search(rf"^\s*{name}:\s*(.*?)\s*$", text, re.M)
        return m.group(1) if m else ""

    info = LockInfo(id=field("ID"), path=field("Path"), who=field("Who"), operation=field("Operation"))
    created = field("Created")
    if created:
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", created)
        if m:
            info.created = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=dt.timezone.utc)
    return info


def claim_prefix(env: str, component: str) -> str:
    return f"{env}/_locks/{component}/"


def claim_key(env: str, component: str, job: Optional[dict] = None) -> str:
    job = job or current_job()
    return f"{claim_prefix(env, component)}{job['build_id']}-{job['job_name'] or 'job'}-{job['job_attempt']}.json"


def other_claims(store: Store, env: str, component: str, me: dict) -> list:
    """Claims of OTHER jobs/attempts for this component, newest first."""
    mine = claim_key(env, component, me)
    out = []
    for key in store.list(claim_prefix(env, component)):
        if key != mine and key.endswith(".json"):
            c = store.get_json(key)
            if c:
                out.append(c)
    return sorted(out, key=lambda c: c.get("started_at", ""), reverse=True)


def current_job() -> dict:
    return {"build_id": os.environ.get("BUILD_BUILDID", "local"), "job_id": os.environ.get("SYSTEM_JOBID", ""),
            "job_name": os.environ.get("SYSTEM_JOBNAME", ""), "job_attempt": int(os.environ.get("SYSTEM_JOBATTEMPT", "1") or 1),
            "stage": os.environ.get("SYSTEM_STAGENAME", ""),
            "started_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}


def ado_build_status(build_id: str) -> tuple[str, str]:
    """(status, result) of a build via the Azure DevOps REST API; ('unknown', '') when it cannot be read."""
    base = os.environ.get("SYSTEM_COLLECTIONURI", "")
    project = os.environ.get("SYSTEM_TEAMPROJECT", "")
    token = os.environ.get("SYSTEM_ACCESSTOKEN", "")
    if not (base and project and token and build_id and build_id != "local"):
        return "unknown", ""
    url = f"{base.rstrip('/')}/{urllib.request.quote(project)}/_apis/build/builds/{build_id}?api-version=7.1"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            doc = json.loads(resp.read().decode())
            return str(doc.get("status", "unknown")), str(doc.get("result", ""))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return "unknown", ""


def decide(lock: LockInfo, holders: list, me: dict, now: dt.datetime,
           status_fn: Callable[[str], tuple], min_age_minutes: float = 10, hard_max_minutes: float = 400) -> tuple[str, str]:
    """('break' | 'wait', reason) given the claims of other jobs. Never 'break' while a claimant runs."""
    age = (now - lock.created).total_seconds() / 60 if lock.created else None
    old_enough = age is not None and age >= min_age_minutes
    stale_reasons = []
    unknown = False
    for h in holders:
        hb = str(h.get("build_id"))
        if hb == str(me.get("build_id")):
            same_job = h.get("job_name") == me.get("job_name") and h.get("stage") == me.get("stage")
            if same_job and int(h.get("job_attempt", 1)) < int(me.get("job_attempt", 1)):
                stale_reasons.append(f"lock left by attempt {h.get('job_attempt')} of this job")
                continue
            return "wait", "lock held by another job of this run"
        status, result = status_fn(hb)
        if status.lower() in RUNNING:
            return "wait", f"holder build {hb} is {status} - never broken"
        if status.lower() == "completed":
            stale_reasons.append(f"holder build {hb} completed ({result or 'unknown result'})")
        else:
            unknown = True
    if age is not None and age >= hard_max_minutes:
        return "break", f"lock older than {hard_max_minutes} min (longer than any job timeout)" + (
            f"; {'; '.join(stale_reasons)}" if stale_reasons else "")
    if unknown:
        return "wait", "a claimant's build status is unknown - not breaking"
    if stale_reasons:
        if old_enough:
            return "break", "; ".join(stale_reasons) + f"; lock age {age:.0f} min"
        return "wait", "; ".join(stale_reasons) + f"; lock younger than {min_age_minutes} min"
    return "wait", "no claim of another job and lock not old enough to be provably stale"


def break_lock(root: Optional[str], lock: LockInfo, account: str, key: str, runner=subprocess.run) -> bool:
    if root and lock.id:
        p = runner(["terraform", f"-chdir={root}", "force-unlock", "-force", lock.id], capture_output=True, text=True)
        if p.returncode == 0:
            return True
    p = runner(["az", "storage", "blob", "lease", "break", "--account-name", account, "--container-name", "tfstate",
                "--blob-name", key, "--auth-mode", "login", "--only-show-errors"], capture_output=True, text=True)
    return p.returncode == 0


def audit(store: Store, env: str, component: str, lock: LockInfo, holder: Optional[dict], reason: str) -> dict:
    now = dt.datetime.now(dt.timezone.utc)
    event = {"event": "state-lock-recovery", "env": env, "component": component, "lock_id": lock.id,
             "lock_created": lock.created.isoformat() if lock.created else None, "lock_who": lock.who,
             "holder": holder, "reason": reason, "by": current_job(), "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    store.put_json(f"{env}/_audit/lock-recovery-{component}-{now.strftime('%Y%m%dT%H%M%S')}.json", event)
    from tools.deploy.retry import log_event

    log_event({"component": component, "label": "state lock", "result": "lock-broken", "reason": reason})
    return event


def recover(output: str, *, env: str, component: str, root: Optional[str], key: str, store: Optional[Store],
            account: str, max_wait_minutes: float = 30, min_age_minutes: float = 10, hard_max_minutes: float = 400,
            status_fn=ado_build_status, sleep=time.sleep, now_fn=lambda: dt.datetime.now(dt.timezone.utc),
            breaker=break_lock) -> bool:
    """True when the lock is gone (broken as stale, or released by its holder while waiting)."""
    lock = parse_lock_info(output)
    me = current_job()
    holders = other_claims(store, env, component, me) if store else []
    waited = 0.0
    delay = 30.0
    while True:
        action, reason = decide(lock, holders, me, now_fn(), status_fn, min_age_minutes, hard_max_minutes)
        print(f"lock doctor: {action} - {reason}")
        if action == "break":
            if breaker(root, lock, account, key):
                if store:
                    audit(store, env, component, lock, holders[0] if holders else None, reason)
                    for h in holders:     # stale claims are cleaned up with the lock
                        store.delete(claim_key(env, component, h))
                print(f"##vso[task.logissue type=warning]stale state lock on {key} broken: {reason}")
                return True
            print(f"##vso[task.logissue type=error]could not break the stale lock on {key}")
            return False
        if waited >= max_wait_minutes * 60:
            print(f"##vso[task.logissue type=error]state lock on {key} still held after {max_wait_minutes} min: {reason}")
            return False
        sleep(delay)
        waited += delay
        delay = min(delay * 2, 300)
        if store:
            fresh = other_claims(store, env, component, me)
            if holders and not fresh:
                return True  # every claimant released its claim: let Terraform retry the lease
            holders = fresh


def recover_from_output(output: str, *, env: str, component: str, root: Optional[str], key: str) -> bool:
    records = os.environ.get("RECORDS_URL")
    account = os.environ.get("STATE_STORAGE_ACCOUNT", "")
    return recover(output, env=env, component=component, root=root, key=key, store=open_store(records),
                   account=account, max_wait_minutes=float(os.environ.get("LOCK_MAX_WAIT_MINUTES", "30")))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("claim", "release", "recover", "inspect"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--store", default=os.environ.get("RECORDS_URL"))
    ap.add_argument("--root")
    ap.add_argument("--error-file")
    ap.add_argument("--max-wait-minutes", type=float, default=30)
    args = ap.parse_args(argv)
    store = open_store(args.store)
    if store is None:
        print("lock doctor: no record store configured - nothing to do")
        return 0
    if args.op == "claim":
        store.put_json(claim_key(args.env, args.component), current_job())
        return 0
    if args.op == "release":
        store.delete(claim_key(args.env, args.component))
        return 0
    if args.op == "inspect":
        print(json.dumps(other_claims(store, args.env, args.component, {"build_id": None}), indent=2))
        return 0
    output = Path(args.error_file).read_text(errors="replace") if args.error_file else sys.stdin.read()
    ok = recover(output, env=args.env, component=args.component, root=args.root,
                 key=f"{args.env}/{args.component}.tfstate", store=store,
                 account=os.environ.get("STATE_STORAGE_ACCOUNT", ""), max_wait_minutes=args.max_wait_minutes)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
