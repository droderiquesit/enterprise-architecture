#!/usr/bin/env python3
"""Copy files to/from a store (local directory or Entra-authenticated blob container).

    python3 tools/deploy/storecp.py put    --store <url|dir> --key <key> --file <path>
    python3 tools/deploy/storecp.py get    --store <url|dir> --key <key> --file <path>
    python3 tools/deploy/storecp.py delete --store <url|dir> --key <key>
    python3 tools/deploy/storecp.py list   --store <url|dir> --prefix <prefix>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import open_store  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("put", "get", "delete", "list"))
    ap.add_argument("--store", required=True)
    ap.add_argument("--key")
    ap.add_argument("--file")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    store = open_store(args.store)
    if args.op == "put":
        store.put_file(Path(args.file), args.key)
    elif args.op == "get":
        if not store.get_file(args.key, Path(args.file)):
            print(f"ERROR: {args.key} not found in {store}", file=sys.stderr)
            return 1
    elif args.op == "delete":
        store.delete(args.key)
    else:
        for k in store.list(args.prefix):
            print(k)
    return 0


if __name__ == "__main__":
    sys.exit(main())
