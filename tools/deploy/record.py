#!/usr/bin/env python3
"""Deployment records: <store>/<env>/<component>.json (container `deployments`).

    python3 tools/deploy/record.py write --env dev --component foundation-network --status succeeded \
        --selection selection.json --store https://<acct>.blob.core.windows.net/deployments [--manifest m.json]
    python3 tools/deploy/record.py show --env dev --component foundation-network --store <store>

Record: {component, env, kind, path, status, deploy_fp, fp_parts, commit, run_id, finished_at,
artifact_digests, contract_versions, contracts_sha, scope, upstream, produces, plan_sha256, note, last_succeeded?}
status: succeeded | failed | partial | canceled | retired.
A non-succeeded record keeps the previous succeeded record under `last_succeeded`; the change
detector re-selects any component whose status is not `succeeded`, which makes re-runs resumable.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import open_store  # noqa: E402

STATUSES = ("succeeded", "failed", "partial", "canceled", "retired", "rolled_back", "quarantined")
FAILURES = ("failed", "partial", "canceled", "rolled_back")
# held: never auto-selected again for the SAME deploy fingerprint (heal / deploy skip it); a new commit touching
# the component or a manual run clears it (tools/changeset/select.py)
HELD = ("rolled_back", "quarantined")
HISTORY = 10
DEFAULT_MAX_CONSECUTIVE_FAILURES = 3


def _commit() -> str:
    if os.environ.get("BUILD_SOURCEVERSION"):
        return os.environ["BUILD_SOURCEVERSION"]
    proc = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True)
    return proc.stdout.strip() or "unknown"


def artifact_digests(metadata_dir: Path) -> dict:
    out = {}
    if metadata_dir and metadata_dir.is_dir():
        for f in sorted(metadata_dir.glob("*/build-metadata.json")):
            m = json.loads(f.read_text())
            out[m.get("component", f.parent.name)] = m.get("digest") or m.get("package_sha256")
    return out


def artifact_metadata(metadata_dir: Path) -> dict:
    """Full release identity per artifact (image@digest, package url + sha256): what rollback restores."""
    out = {}
    if metadata_dir and metadata_dir.is_dir():
        for f in sorted(metadata_dir.glob("*/build-metadata.json")):
            m = json.loads(f.read_text())
            out[m.get("component", f.parent.name)] = {k: m.get(k) for k in
                                                       ("name", "image", "digest", "package_url", "package_sha256", "tag")}
    return out


def max_consecutive_failures(env: str) -> int:
    try:
        import yaml

        doc = yaml.safe_load((Path(__file__).resolve().parents[2] / f"environments/{env}/environment.yaml").read_text())
        return int(((doc or {}).get("self_healing") or {}).get("max_consecutive_failures", DEFAULT_MAX_CONSECUTIVE_FAILURES))
    except Exception:  # noqa: BLE001
        return DEFAULT_MAX_CONSECUTIVE_FAILURES


def make_record(env: str, component: str, status: str, selection: dict, previous: dict | None,
                commit: str, run_id: str, manifest: dict | None = None, note: str | None = None,
                digests: dict | None = None, artifacts: dict | None = None, threshold: int | None = None) -> dict:
    """Builds the new record. Failure bookkeeping (circuit breaker): consecutive_failures counts failed /
    partial / canceled / rolled_back results; when it reaches `threshold` the record becomes `quarantined`
    (reason kept) and heal/auto-retry stop selecting it until a new commit or a manual run."""
    if status not in STATUSES:
        raise ValueError(f"status must be one of {STATUSES}")
    entry = selection["components"].get(component) or {}
    record = {
        "component": component,
        "env": env,
        "kind": entry.get("kind", "terraform"),
        "path": entry.get("path"),
        "status": status,
        "deploy_fp": entry.get("deploy_fp"),
        "fp_parts": entry.get("fp_parts"),
        "commit": commit,
        "run_id": run_id,
        "finished_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "artifact_digests": digests or {},
        "contract_versions": entry.get("contract_versions", {}),
        "upstream": entry.get("upstream", []),
        "produces": entry.get("produces", []),
        "plan_sha256": (manifest or {}).get("plan_sha256"),
        # contracts this deployment was planned with: a later difference re-selects the component
        "contracts_sha": (manifest or {}).get("contracts_sha"),
        "scope": entry.get("scope"),
        "mode": selection.get("mode"),
        "note": note,
        "artifacts": artifacts or {},
    }
    previous = previous or {}
    prev_fail = int(previous.get("consecutive_failures", 0) or 0)
    record["consecutive_failures"] = prev_fail + 1 if status in FAILURES else 0
    record["history"] = ([{"status": status, "run_id": run_id, "finished_at": record["finished_at"],
                           "deploy_fp": record["deploy_fp"], "note": note}] + list(previous.get("history") or []))[:HISTORY]
    if previous.get("verification") and status != "succeeded":
        record["verification"] = previous["verification"]
    limit = threshold if threshold is not None else DEFAULT_MAX_CONSECUTIVE_FAILURES
    if status in FAILURES and record["consecutive_failures"] >= limit:
        record["last_status"] = status
        record["status"] = "quarantined"
        record["quarantine"] = {"since": record["finished_at"], "failures": record["consecutive_failures"],
                                "reason": f"{record['consecutive_failures']} consecutive failed deployments "
                                          f"(last: {status}{': ' + note if note else ''})"}
    if status != "succeeded" and previous:
        prev_ok = previous if previous.get("status") == "succeeded" else previous.get("last_succeeded")
        if prev_ok:
            record["last_succeeded"] = {k: v for k, v in prev_ok.items() if k != "last_succeeded"}
    return record


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("write", "show", "verify"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--store", required=True)
    ap.add_argument("--status", choices=STATUSES)
    ap.add_argument("--selection")
    ap.add_argument("--manifest")
    ap.add_argument("--note")
    ap.add_argument("--commit")
    ap.add_argument("--run-id")
    ap.add_argument("--artifact-metadata-dir", default=os.environ.get("ARTIFACT_METADATA_DIR"))
    ap.add_argument("--verification", choices=("passed", "failed"), help="verify: smoke/telemetry outcome")
    ap.add_argument("--smoke-results", help="verify: tools/smoke/smoke.py results JSON (all components in it)")
    args = ap.parse_args(argv)
    store = open_store(args.store)
    key = f"{args.env}/{args.component}.json"
    if args.op == "show":
        print(json.dumps(store.get_json(key), indent=2, sort_keys=True))
        return 0
    if args.op == "verify":
        return cmd_verify(args, store)
    if not args.status or not args.selection:
        ap.error("write needs --status and --selection")
    selection = json.loads(Path(args.selection).read_text())
    manifest = json.loads(Path(args.manifest).read_text()) if args.manifest and Path(args.manifest).exists() else None
    record = make_record(args.env, args.component, args.status, selection, store.get_json(key),
                         args.commit or _commit(), args.run_id or os.environ.get("BUILD_BUILDID", "local"),
                         manifest, args.note,
                         artifact_digests(Path(args.artifact_metadata_dir)) if args.artifact_metadata_dir else {},
                         artifact_metadata(Path(args.artifact_metadata_dir)) if args.artifact_metadata_dir else {},
                         max_consecutive_failures(args.env))
    store.put_json(key, record)
    print(f"record {key}: status={record['status']} deploy_fp={record['deploy_fp']} "
          f"consecutive_failures={record['consecutive_failures']}")
    if record["status"] == "quarantined":
        print(f"##vso[task.logissue type=error]{args.component} QUARANTINED: {record['quarantine']['reason']}")
        print("QUARANTINED")
    return 0


def cmd_verify(args, store) -> int:
    """Attach the post-deployment verification outcome to existing records (heal re-runs failed ones)."""
    outcomes = {}
    if args.smoke_results:
        res = json.loads(Path(args.smoke_results).read_text())
        for cid, r in (res.get("components") or {}).items():
            if r.get("status") in ("passed", "failed"):
                outcomes[cid] = r["status"]
    elif args.verification:
        outcomes[args.component] = args.verification
    run_id = args.run_id or os.environ.get("BUILD_BUILDID", "local")
    for cid, status in outcomes.items():
        if args.component not in ("*", cid) and not args.smoke_results:
            continue
        key = f"{args.env}/{cid}.json"
        rec = store.get_json(key)
        if not rec:
            continue
        rec["verification"] = {"status": status, "run_id": run_id,
                               "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        store.put_json(key, rec)
        print(f"record {key}: verification={status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
