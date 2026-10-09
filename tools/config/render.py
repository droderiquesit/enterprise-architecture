#!/usr/bin/env python3
"""Render <root>/terraform.tfvars.json for one component and print its sha256.

    python3 tools/config/render.py --env dev --component foundation-network [--stdout] [--ado]

Content: {"environment": <ADR §6 globals>, "settings": environment.components.<id> or {}}
plus optional globals (network, datadog, budget, features, profile_name) that the root declares
as variables. The printed sha256 is over the canonical JSON and is part of the plan binding
manifest and of the component fingerprint.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.config.lib import (  # noqa: E402
    ConfigError,
    canonical_json,
    load_environment,
    load_profile,
    render_component,
    sha256_text,
)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--stdout", action="store_true", help="print JSON instead of writing the file")
    ap.add_argument("--ado", action="store_true", help="emit ##vso output variable config_sha")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    tree = WorkTree(repo)
    try:
        registry = load_registry(tree)
        comp = registry.get(args.component)
        if not comp.is_terraform:
            raise ConfigError(f"{args.component} is not a terraform component")
        env_doc = load_environment(tree, args.env)
        profile_doc = load_profile(tree, env_doc.get("profile", "minimal"))
        rendered = render_component(tree, registry, env_doc, profile_doc, args.component)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    text = canonical_json(rendered)
    digest = sha256_text(text)
    if args.stdout:
        print(text)
    else:
        target = repo / comp.path / "terraform.tfvars.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text + "\n", encoding="utf-8")
        print(digest)
    if args.ado:
        print(f"##vso[task.setvariable variable=config_sha;isOutput=true]{digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
