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

STATUSES = ("succeeded", "failed", "partial", "canceled", "retired")


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


def make_record(env: str, component: str, status: str, selection: dict, previous: dict | None,
                commit: str, run_id: str, manifest: dict | None = None, note: str | None = None,
                digests: dict | None = None) -> dict:
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
    }
    if status != "succeeded" and previous:
        prev_ok = previous if previous.get("status") == "succeeded" else previous.get("last_succeeded")
        if prev_ok:
            record["last_succeeded"] = {k: v for k, v in prev_ok.items() if k != "last_succeeded"}
    return record


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("write", "show"))
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
    args = ap.parse_args(argv)
    store = open_store(args.store)
    key = f"{args.env}/{args.component}.json"
    if args.op == "show":
        print(json.dumps(store.get_json(key), indent=2, sort_keys=True))
        return 0
    if not args.status or not args.selection:
        ap.error("write needs --status and --selection")
    selection = json.loads(Path(args.selection).read_text())
    manifest = json.loads(Path(args.manifest).read_text()) if args.manifest and Path(args.manifest).exists() else None
    record = make_record(args.env, args.component, args.status, selection, store.get_json(key),
                         args.commit or _commit(), args.run_id or os.environ.get("BUILD_BUILDID", "local"),
                         manifest, args.note,
                         artifact_digests(Path(args.artifact_metadata_dir)) if args.artifact_metadata_dir else {})
    store.put_json(key, record)
    print(f"record {key}: status={record['status']} deploy_fp={record['deploy_fp']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
