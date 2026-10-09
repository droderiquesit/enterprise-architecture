#!/usr/bin/env python3
"""JSON Schema validation for contracts (catalog/contracts/*.schema.json, JSON Schema 2020-12).

    python3 tools/contracts/validate.py --all                       # schemas well-formed, coverage report
    python3 tools/contracts/validate.py --contract foundation-network --file data.json
    python3 tools/contracts/validate.py --envelope envelope.json --env dev

--file accepts raw contract data or an envelope (detected by its `contract` + `data` keys).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.contracts.lib import expected_major, validate_data, validate_envelope  # noqa: E402

SCHEMA_RE = re.compile(r"^catalog/contracts/([a-z0-9-]+)\.v(\d+)\.schema\.json$")


def check_all(repo: Path) -> int:
    import jsonschema

    tree = WorkTree(repo)
    rc = 0
    found = {}
    for path in sorted(tree.files()):
        m = SCHEMA_RE.match(path)
        if not m:
            continue
        try:
            jsonschema.Draft202012Validator.check_schema(json.loads(tree.read_text(path)))
            found.setdefault(m[1], []).append(int(m[2]))
            print(f"ok      {path}")
        except Exception as exc:  # noqa: BLE001
            print(f"INVALID {path}: {exc}")
            rc = 1
    reg = load_registry(tree)
    missing = sorted({p for c in reg for p in c.produces if p not in found and c.pipeline != "manual"})
    consumed = {e for c in reg for e in c.consumes + c.optional_consumes}
    for name in missing:
        level = "warning" if name not in consumed else "warning (consumed!)"
        print(f"{level}: no schema for produced contract '{name}'")
    return rc


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--contract")
    ap.add_argument("--file")
    ap.add_argument("--envelope")
    ap.add_argument("--env", default="dev")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    if args.all:
        return check_all(repo)
    tree = WorkTree(repo)
    path = args.envelope or args.file
    if not path:
        ap.error("--all, --file or --envelope required")
    doc = json.loads(Path(path).read_text())
    if args.envelope or (isinstance(doc, dict) and {"contract", "data"} <= set(doc)):
        contract = doc.get("contract")
        errors = validate_envelope(tree, doc, contract, args.env if args.envelope else doc.get("environment"),
                                   expected_major(tree, contract))
    else:
        if not args.contract:
            ap.error("--contract required for raw data")
        errors = validate_data(tree, args.contract, expected_major(tree, args.contract), doc)
    for e in errors:
        print(f"ERROR: {e}")
    print("valid" if not errors else f"{len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
