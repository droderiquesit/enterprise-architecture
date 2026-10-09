#!/usr/bin/env python3
"""Copy one pipeline run's evidence from the `evidence` store into the repository.

    python3 tools/report/pull_evidence.py --store https://<state account>.blob.core.windows.net/evidence \
        --env dev --run-id 1234 [--dest docs/evidence] [--force]
    python3 tools/report/pull_evidence.py --store /path/to/local/evidence-dir --env dev --run-id 1234   # offline

The evidence stage (pipelines/templates/evidence.yml) uploads `<env>/runs/<run id>/{evidence.json,deployment-report.md}`
to the `evidence` container. ADR-0001 section 11 allows `deployed` / `verified` claims only with an evidence file in
`docs/evidence/`; this tool downloads every object under that prefix into `docs/evidence/<env>/<run id>/`, checks that
`evidence.json` belongs to the requested environment and run, refuses files with secret-looking keys, and writes
`SOURCE.json` (store, keys, sha256 per file) so the copy can be traced. Committing the result is a reviewed change.

--store accepts the same locations as tools/changeset/store.py: an https blob container URL (Azure CLI, Entra auth:
`az login`; needs Storage Blob Data Reader on `evidence`), a file:// URL or a local directory (tests, offline copies).

Exit codes: 0 copied, 1 nothing found / validation failed / destination exists (without --force), 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import StoreError, open_store  # noqa: E402
from tools.contracts.lib import secret_like_keys  # noqa: E402

SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
RUN_ID = re.compile(r"^[A-Za-z0-9._-]+$")


class EvidenceError(Exception):
    pass


def pull(store, env: str, run_id: str, dest_root: Path, force: bool = False) -> dict:
    if not RUN_ID.match(run_id) or not RUN_ID.match(env):
        raise EvidenceError("env and run id may contain only letters, digits, '.', '_' and '-'")
    prefix = f"{env}/runs/{run_id}/"
    keys = [k for k in store.list(prefix) if k.startswith(prefix) and not k.endswith("/")]
    if not keys:
        raise EvidenceError(f"no evidence under '{prefix}' in {store!r}")
    dest = dest_root / env / run_id
    if dest.exists() and any(dest.iterdir()) and not force:
        raise EvidenceError(f"{dest} already exists (use --force to overwrite)")

    files: dict[str, bytes] = {}
    for key in sorted(keys):
        rel = key[len(prefix):]
        parts = rel.split("/")
        if any(not SAFE_NAME.match(p) or p in (".", "..") for p in parts):
            raise EvidenceError(f"refusing unsafe object name '{key}'")
        data = store.get_bytes(key)
        if data is None:
            raise EvidenceError(f"object vanished while copying: {key}")
        if rel.endswith(".json"):
            try:
                doc = json.loads(data)
            except ValueError as exc:
                raise EvidenceError(f"{key}: not valid JSON ({exc})") from None
            bad = secret_like_keys(doc)
            if bad:
                raise EvidenceError(f"{key}: secret-looking keys {bad[:5]} - not copying")
        files[rel] = data

    ev = files.get("evidence.json")
    if ev is None:
        raise EvidenceError(f"'{prefix}evidence.json' missing - not a complete evidence set")
    doc = json.loads(ev)
    if str(doc.get("environment")) != env or str(doc.get("run_id")) != str(run_id):
        raise EvidenceError(f"evidence.json is for environment={doc.get('environment')!r} run_id={doc.get('run_id')!r}, "
                            f"expected {env!r}/{run_id!r}")

    dest.mkdir(parents=True, exist_ok=True)
    for rel, data in files.items():
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    source = {
        "store": repr(store), "prefix": prefix, "environment": env, "run_id": run_id, "commit": doc.get("commit"),
        "files": {rel: hashlib.sha256(data).hexdigest() for rel, data in sorted(files.items())},
    }
    (dest / "SOURCE.json").write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")
    statuses: dict[str, int] = {}
    for c in (doc.get("components") or {}).values():
        statuses[c.get("status", "?")] = statuses.get(c.get("status", "?"), 0) + 1
    return {"dest": str(dest), "files": sorted(files), "statuses": statuses}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--store", required=True, help="evidence container URL, file:// URL or local directory")
    ap.add_argument("--env", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--dest", default="docs/evidence", help="destination root (default docs/evidence)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing docs/evidence/<env>/<run id>/")
    args = ap.parse_args(argv)
    try:
        store = open_store(args.store)
        result = pull(store, args.env, args.run_id, Path(args.dest), args.force)
    except (EvidenceError, StoreError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
