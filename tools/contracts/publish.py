#!/usr/bin/env python3
"""Publish a component's output contract(s) as envelopes, or check that they exist.

    python3 tools/contracts/publish.py publish --env dev --component foundation-network \
        --root foundation/network --store https://<acct>.blob.core.windows.net/contracts
    python3 tools/contracts/publish.py check --env dev --component foundation-network --store <store>

publish: `terraform -chdir=<root> output -json <contract output>` (or --output-json FILE) →
validate against catalog/contracts/<contract>.v<major>.schema.json → reject secret-looking values →
upload {contract, version, environment, produced_by, data} to <env>/<contract>/v<major>.json.
Emits ##vso output `contract_changed` ('true' when the data differs from the previous envelope).
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

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.store import open_store  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.contracts.lib import (  # noqa: E402
    ContractError,
    envelope_key,
    expected_major,
    produced_contracts,
    secret_like_keys,
    validate_envelope,
)


def _commit(repo: Path) -> str:
    if os.environ.get("BUILD_SOURCEVERSION"):
        return os.environ["BUILD_SOURCEVERSION"]
    proc = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True)
    return proc.stdout.strip() or "unknown"


def terraform_output(root: Path, name: str):
    proc = subprocess.run(["terraform", f"-chdir={root}", "output", "-json", name], capture_output=True, text=True)
    if proc.returncode != 0:
        raise ContractError(f"terraform output {name} failed: {proc.stderr.strip()[:400]}")
    return json.loads(proc.stdout)


def build_envelope(tree, env: str, component, contract: str, data, commit: str, run_id: str, minor: int = 0) -> dict:
    major = expected_major(tree, contract)
    envelope = {
        "contract": contract,
        "version": f"{major}.{minor}.0",
        "environment": env,
        "produced_by": {
            "component": component.id,
            "commit": commit,
            "run_id": run_id,
            "produced_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "data": data,
    }
    problems = validate_envelope(tree, envelope, contract, env, major)
    secrets = secret_like_keys(data)
    if secrets:
        problems.append("contract contains secret-looking values (publish dsv:// references, never values - ADR-0001 section 14): "
                        + ", ".join(secrets))
    if problems:
        raise ContractError(f"contract {contract} rejected:\n  " + "\n  ".join(problems))
    return envelope


def cmd_publish(args) -> int:
    repo = Path(args.repo).resolve()
    tree = WorkTree(repo)
    comp = load_registry(tree).get(args.component)
    store = open_store(args.store)
    outputs = produced_contracts(comp)
    if not outputs:
        print(f"{comp.id} produces no contract")
        return 0
    changed = False
    for contract, output_name in outputs.items():
        if args.output_json:
            raw = json.loads(Path(args.output_json).read_text())
            data = raw.get(output_name, raw) if isinstance(raw, dict) and output_name in raw else raw
        else:
            data = terraform_output(repo / (args.root or comp.path), output_name)
        envelope = build_envelope(tree, args.env, comp, contract, data, args.commit or _commit(repo),
                                  args.run_id or os.environ.get("BUILD_BUILDID", "local"))
        key = envelope_key(args.env, contract, expected_major(tree, contract))
        previous = store.get_json(key)
        changed = changed or previous is None or previous.get("data") != data
        store.put_json(key, envelope)
        print(f"published {contract} -> {key}")
    print(f"##vso[task.setvariable variable=contract_changed;isOutput=true]{'true' if changed else 'false'}")
    return 0


def cmd_check(args) -> int:
    tree = WorkTree(Path(args.repo).resolve())
    comp = load_registry(tree).get(args.component)
    store = open_store(args.store)
    missing = [c for c in comp.produces if store.get_json(envelope_key(args.env, c, expected_major(tree, c))) is None]
    if missing:
        print(f"missing contract envelopes: {', '.join(missing)}")
        return 1
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("publish")
    p.add_argument("--env", required=True)
    p.add_argument("--component", required=True)
    p.add_argument("--root")
    p.add_argument("--store", required=True)
    p.add_argument("--output-json", help="use this JSON instead of terraform output (tests)")
    p.add_argument("--commit")
    p.add_argument("--run-id")
    p.set_defaults(func=cmd_publish)
    c = sub.add_parser("check")
    c.add_argument("--env", required=True)
    c.add_argument("--component", required=True)
    c.add_argument("--store", required=True)
    c.set_defaults(func=cmd_check)
    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
