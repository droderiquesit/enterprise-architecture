"""Validate `output "contract"` of a Terraform root/module against its JSON schema, using the plans
produced by its own mock-provider `terraform test` runs (`terraform test -verbose -json`).

usage: python3 contract_check.py <terraform-dir> <schema.json> [--require-runs N]
Every passing run whose planned `contract` output is fully known is validated; expect_failures runs
(no plan) are skipped. Exit 1 on any schema violation or if fewer than N contracts were checked.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import jsonschema


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tfdir")
    ap.add_argument("schema")
    ap.add_argument("--require-runs", type=int, default=1)
    args = ap.parse_args()

    schema = json.load(open(args.schema))
    validator = jsonschema.Draft202012Validator(schema)
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    proc = subprocess.run([tf, "test", "-verbose", "-json"], cwd=args.tfdir, capture_output=True, text=True)
    checked, errors = 0, []
    for line in proc.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") != "test_plan":
            continue
        oc = ev["test_plan"].get("output_changes", {}).get("contract")
        if not oc or oc.get("after_unknown") not in (False, None, {}):
            continue
        run = ev.get("@testrun")
        errs = sorted(validator.iter_errors(oc["after"]), key=lambda e: list(e.path))
        checked += 1
        for e in errs:
            errors.append(f"{run}: {'/'.join(map(str, e.path))}: {e.message}")
        print(f"{'FAIL' if errs else 'PASS'} contract schema: {args.tfdir} run={run}")
    for e in errors:
        print("  " + e)
    if checked < args.require_runs:
        print(f"only {checked} contract(s) checked (< {args.require_runs}); terraform test rc={proc.returncode}")
        print(proc.stderr[-2000:])
        return 1
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
