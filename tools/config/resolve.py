#!/usr/bin/env python3
"""Resolve the enabled component set of an environment (profile + custom selection).

    python3 tools/config/resolve.py --env dev [--json] [--profile enterprise]

Exit codes: 0 ok, 1 configuration error (message explains the missing dependency).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.graph import Graph  # noqa: E402
from tools.changeset.registry import RegistryError, load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.config.lib import ConfigError, load_environment, load_profile, resolve_enabled  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--profile", help="override the environment's profile (for what-if checks)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    tree = WorkTree(Path(args.repo))
    try:
        registry = load_registry(tree)
        graph = Graph(registry)
        graph.check_acyclic()
        env_doc = load_environment(tree, args.env)
        profile_doc = load_profile(tree, args.profile or env_doc.get("profile", "minimal"))
        enabled, notes = resolve_enabled(registry, graph, env_doc, profile_doc)
    except (ConfigError, RegistryError, Exception) as exc:  # noqa: BLE001 - CLI boundary
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"environment": args.env, "profile": profile_doc.get("profile"),
                          "enabled": sorted(enabled), "notes": notes}, indent=2))
    else:
        print(f"profile: {profile_doc.get('profile')}  enabled components: {len(enabled)}")
        for cid in sorted(enabled):
            print(f"  {cid}")
        for n in notes:
            print(f"  note: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
