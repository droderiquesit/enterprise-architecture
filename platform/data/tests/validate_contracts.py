#!/usr/bin/env python3
"""Validates every platform/data root's `contract` output against its JSON schema, using the plans
produced by the mocked `terraform test` runs (no Azure credentials needed), plus static policy checks.

Usage (from the repository root):
    python3 platform/data/tests/validate_contracts.py [root ...]

For each root: `terraform init -backend=false` (if needed), `terraform test -verbose -json`, then every
run's planned `output.contract` is validated against catalog/contracts/<contract>.v1.schema.json.
Values that are unknown at plan time are replaced by a resource-ID-shaped placeholder.
Static checks over platform/data and platform/modules/data-*:
  * no azurerm_redis_cache (legacy, retiring) and no azurerm_monitor_diagnostic_setting (observability owns them)
  * no Datadog provider/resources (observability owns DBM users and checks)
  * no secret-looking keys in contracts (only *_secret_id / *_secret_name references)
"""
import json
import pathlib
import re
import subprocess
import sys

import jsonschema

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = REPO / "platform" / "data"
SCHEMAS = REPO / "catalog" / "contracts"
ROOT_CONTRACT = {
    "sql": "platform-db-sql", "sqlmi": "platform-db-sqlmi", "sqlvm": "platform-db-sqlvm",
    "postgresql": "platform-db-postgresql", "mysql": "platform-db-mysql",
    "cosmos-nosql": "platform-db-cosmos-nosql", "cosmos-mongo": "platform-db-cosmos-mongo",
    "cosmos-cassandra": "platform-db-cosmos-cassandra", "cosmos-gremlin": "platform-db-cosmos-gremlin",
    "cosmos-table": "platform-db-cosmos-table", "documentdb": "platform-db-documentdb",
    "cassandra-mi": "platform-db-cassandra-mi", "redis": "platform-db-redis",
    "table-storage": "platform-db-table-storage", "ledger": "platform-db-ledger",
    "horizondb": "platform-db-horizondb", "analytics": "platform-data-analytics",
}
PLACEHOLDER = "/subscriptions/00000000-0000-0000-0000-000000000000/unknown-at-plan"
SECRET_KEY = re.compile(r"(password|secret|connection_string|access_key|primary_key|token)$", re.I)


def fill_unknown(after, unknown):
    if unknown is True:
        return PLACEHOLDER
    if isinstance(after, dict) and isinstance(unknown, dict):
        out = dict(after)
        for k, u in unknown.items():
            out[k] = fill_unknown(after.get(k), u)
        return out
    if isinstance(after, list) and isinstance(unknown, list):
        return [fill_unknown(a, u) for a, u in zip(after, unknown)] + after[len(unknown):]
    if after is None and isinstance(unknown, dict):
        return fill_unknown({}, unknown)
    if after is None and isinstance(unknown, list):
        return fill_unknown([], unknown) if unknown else []
    return after


def secret_keys(value, path="$"):
    bad = []
    if isinstance(value, dict):
        for k, v in value.items():
            if SECRET_KEY.search(k) and v not in (None, "") and not k.endswith(("_secret_id", "_secret_name")):
                bad.append(f"{path}.{k}")
            bad += secret_keys(v, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            bad += secret_keys(v, f"{path}[{i}]")
    return bad


def static_checks():
    errors = []
    files = list(DATA.rglob("*.tf")) + list((REPO / "platform" / "modules").glob("data-*/**/*.tf"))
    for f in files:
        if ".terraform" in f.parts:
            continue
        text = f.read_text()
        for pattern, why in [
            (r'resource\s+"azurerm_redis_cache"', "azurerm_redis_cache is retiring; use azurerm_managed_redis"),
            (r'resource\s+"azurerm_monitor_diagnostic_setting"', "diagnostic settings are owned by obs-diagnostics"),
            (r'"datadog_|DataDog/datadog', "Datadog resources are owned by observability"),
        ]:
            if re.search(pattern, text):
                errors.append(f"{f.relative_to(REPO)}: {why}")
    return errors


def run_root(name):
    root = DATA / name
    if not (root / ".terraform").exists():
        subprocess.run(["terraform", "init", "-backend=false", "-input=false"], cwd=root, check=True,
                       stdout=subprocess.DEVNULL)
    proc = subprocess.run(["terraform", "test", "-verbose", "-json"], cwd=root, capture_output=True, text=True)
    schema = json.loads((SCHEMAS / f"{ROOT_CONTRACT[name]}.v1.schema.json").read_text())
    validator = jsonschema.Draft202012Validator(schema)
    checked, errors = 0, []
    for line in proc.stdout.splitlines():
        msg = json.loads(line)
        if msg.get("type") == "test_run" and msg.get("test_run", {}).get("status") in ("fail", "error"):
            errors.append(f"{name}: run {msg['test_run'].get('run')} {msg['test_run']['status']}")
        if msg.get("type") != "test_plan":
            continue
        change = msg["test_plan"].get("output_changes", {}).get("contract")
        if not change:
            continue
        contract = fill_unknown(change.get("after"), change.get("after_unknown"))
        run = msg.get("@testrun")
        for err in validator.iter_errors(contract):
            errors.append(f"{name}/{run}: {'/'.join(map(str, err.absolute_path))}: {err.message}")
        for key in secret_keys(contract):
            errors.append(f"{name}/{run}: secret-looking key in contract: {key}")
        checked += 1
    if proc.returncode != 0:
        errors.append(f"{name}: terraform test exited {proc.returncode}")
    if checked == 0:
        errors.append(f"{name}: no contract found in test plans")
    return checked, errors


def main(argv):
    names = argv or sorted(ROOT_CONTRACT)
    all_errors = static_checks()
    for name in names:
        checked, errors = run_root(name)
        status = "ok" if not errors else "FAIL"
        print(f"{status:4} {name:18} contracts validated: {checked}")
        all_errors += errors
    for e in all_errors:
        print("  -", e)
    return 1 if all_errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
