#!/usr/bin/env python3
"""Assemble <root>/contracts.auto.tfvars.json from upstream contract envelopes.

    python3 tools/contracts/materialize.py --env dev --component platform-aks \
        --source https://<acct>.blob.core.windows.net/contracts      (or a local directory)

For every `consumes` entry: download <env>/<contract>/v<major>.json, check the envelope, its major
version (= highest catalog/contracts/<contract>.v<N>.schema.json at this commit) and the data schema,
and write `<contract with - → _> = <data>`. Required contracts that are missing fail with an explicit
message; `optional_consumes` are included only when their producer is enabled in the environment
(and published). Components with `discovers_resources: true` that declare
`variable "discovered_contracts"` also get {contract: data} for every enabled platform/applications
producer that has published. Prints the sha256 of the written JSON (plan binding input).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.graph import Graph  # noqa: E402
from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.store import open_store  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.config.lib import declared_variables, resolve_for_env  # noqa: E402
from tools.contracts.lib import (  # noqa: E402
    ContractError,
    envelope_key,
    expected_major,
    validate_envelope,
    var_name,
    write_json,
)


def materialize(repo: Path, env: str, component: str, store, write: bool = True):
    tree = WorkTree(repo)
    reg = load_registry(tree)
    graph = Graph(reg)
    enabled, _env_doc, _profile, _ = resolve_for_env(tree, reg, graph, env)
    values, notes = contract_values(tree, reg, enabled, env, component, store)
    c = reg.get(component)
    digest = values_digest(values)
    if write:
        digest = write_json(repo / c.path / "contracts.auto.tfvars.json", values)
    return values, digest, notes


def values_digest(values: dict) -> str:
    """Same digest as the written contracts.auto.tfvars.json (tools/contracts/lib.write_json)."""
    import hashlib

    text = json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


def contract_values(tree, reg, enabled, env: str, component: str, store):
    """Variables for one root from the published envelopes (no file written). Raises ContractError."""
    c = reg.get(component)
    declared = declared_variables(tree, c.path)
    optional = set(c.optional_consumes)
    values = {}
    notes, errors = [], []
    for entry in list(dict.fromkeys(list(c.consumes) + list(c.optional_consumes))):
        producer = reg.producer_of(entry)
        is_optional = entry in optional
        if is_optional and producer not in enabled:
            notes.append(f"optional {entry}: producer {producer} not enabled - skipped")
            continue
        major = expected_major(tree, entry)
        envelope = store.get_json(envelope_key(env, entry, major)) if store else None
        if envelope is None:
            msg = f"{entry} v{major} not published for '{env}' (key {envelope_key(env, entry, major)}); deploy {producer} first"
            (notes if is_optional else errors).append(("optional " if is_optional else "required ") + msg)
            continue
        problems = validate_envelope(tree, envelope, entry, env, major)
        if problems:
            errors.extend(problems)
            continue
        name = var_name(entry)
        if declared and name not in declared:
            notes.append(f"{entry}: root does not declare variable '{name}' - not written")
            continue
        values[name] = envelope["data"]
    if c.discovers_resources and "discovered_contracts" in declared:
        discovered = {}
        for other in reg:
            if other.id in enabled and other.layer in ("platform", "applications") and other.produces:
                for contract in other.produces:
                    major = expected_major(tree, contract)
                    env_ = store.get_json(envelope_key(env, contract, major)) if store else None
                    if env_ and not validate_envelope(tree, env_, contract, env, major):
                        discovered[contract] = env_["data"]
        values["discovered_contracts"] = discovered
    if errors:
        raise ContractError("cannot materialize contracts for " + component + ":\n  " + "\n  ".join(errors))
    return values, notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--source", required=True, help="contracts store: directory or https blob container URL")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    try:
        _values, digest, notes = materialize(Path(args.repo).resolve(), args.env, args.component, open_store(args.source))
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for n in notes:
        print(f"note: {n}", file=sys.stderr)
    print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
