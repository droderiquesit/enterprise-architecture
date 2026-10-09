#!/usr/bin/env python3
"""Plan binding manifest: ties a saved plan to exactly the inputs it was created from.

    create  --component --env --root --plan tfplan --binding binding.json --plan-key K --exit-code N --out manifest.json
    verify  --manifest manifest.json --component --env --root --plan tfplan --binding binding.json

Manifest fields: component, env, commit, config_sha, contracts_sha, artifacts_sha,
tool_versions {terraform, lockfile_sha256}, plan_sha256, plan_key, exit_code, has_changes,
run_id, job_attempt, created_at.

verify (run in the Apply job right before `terraform apply`) recomputes every field from the apply
job's own checkout/rendering and refuses to apply when anything differs. A contracts difference
means an upstream stage re-published its contract after this plan was made:
"stale plan; re-run" (re-running the stage re-plans automatically).
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

BOUND_FIELDS = ("component", "env", "commit", "config_sha", "contracts_sha", "artifacts_sha")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def terraform_version() -> str:
    override = os.environ.get("PLAN_MANIFEST_TERRAFORM_VERSION")
    if override:
        return override
    proc = subprocess.run(["terraform", "version", "-json"], capture_output=True, text=True)
    if proc.returncode != 0:
        return "unknown"
    return json.loads(proc.stdout).get("terraform_version", "unknown")


def current_commit(root: Path) -> str:
    if os.environ.get("BUILD_SOURCEVERSION"):
        return os.environ["BUILD_SOURCEVERSION"]
    proc = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True)
    return proc.stdout.strip() or "unknown"


def tool_versions(root: Path) -> dict:
    lock = root / ".terraform.lock.hcl"
    return {"terraform": terraform_version(), "lockfile_sha256": sha256_file(lock) if lock.exists() else None}


def build(component: str, env: str, root: Path, plan: Path, binding: dict) -> dict:
    return {
        "component": component,
        "env": env,
        "commit": current_commit(root),
        "config_sha": binding.get("config_sha"),
        "contracts_sha": binding.get("contracts_sha"),
        "artifacts_sha": binding.get("artifacts_sha"),
        "tool_versions": tool_versions(root),
        "plan_sha256": sha256_file(plan),
    }


def compare(manifest: dict, current: dict) -> list[str]:
    problems = []
    for f in BOUND_FIELDS:
        if manifest.get(f) != current.get(f):
            if f == "contracts_sha":
                problems.append("stale plan; re-run: upstream contracts changed since the plan was created "
                                f"({manifest.get(f)} -> {current.get(f)})")
            else:
                problems.append(f"{f} differs: plan={manifest.get(f)} now={current.get(f)}")
    if manifest.get("tool_versions") != current.get("tool_versions"):
        problems.append(f"tool versions differ: plan={manifest.get('tool_versions')} now={current.get('tool_versions')}")
    if manifest.get("plan_sha256") != current.get("plan_sha256"):
        problems.append("plan file digest differs from the reviewed plan (tampered or wrong blob)")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("create", "verify"))
    ap.add_argument("--component", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--binding", required=True)
    ap.add_argument("--plan-key")
    ap.add_argument("--exit-code", type=int)
    ap.add_argument("--out")
    ap.add_argument("--manifest")
    args = ap.parse_args(argv)
    binding = json.loads(Path(args.binding).read_text())
    current = build(args.component, args.env, Path(args.root), Path(args.plan), binding)
    if args.op == "create":
        current.update({
            "plan_key": args.plan_key,
            "exit_code": args.exit_code,
            "has_changes": args.exit_code == 2,
            "run_id": os.environ.get("BUILD_BUILDID", "local"),
            "job_attempt": os.environ.get("SYSTEM_JOBATTEMPT", "1"),
            "created_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        print(f"manifest written: plan_sha256={current['plan_sha256']}")
        return 0
    manifest = json.loads(Path(args.manifest).read_text())
    problems = compare(manifest, current)
    if problems:
        for p in problems:
            print(f"##vso[task.logissue type=error]{p}")
            print(f"ERROR: {p}", file=sys.stderr)
        return 1
    print("plan binding verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
