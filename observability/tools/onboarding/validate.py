#!/usr/bin/env python3
"""Validate ServiceOnboarding v2 manifests (schema + semantic checks) against the tag policy.

Semantic checks
  * every manifest renders for each of its environments (tag policy required keys present, allowed values)
  * unique service per env; unique resource roles per manifest; literal resource ids are ARM ids
  * the tag policy itself is valid (schemas/tag-policy.v1.schema.json)
  * notices (never fail --strict): content sections (monitors, notifications, catalog, endpoints, slos, ...) that the
    core package ignores, and the deprecated --routing / --archetypes options

Exit codes: 0 valid (warnings allowed unless --strict), 1 invalid, 2 usage error. Output: text, or JSON with --json.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import onboarding_lib as lib
from tag_policy import PolicyError, TagPolicy


def validate(manifests: list[Path], envs: list[str] | None, tag_policy: Path | None) -> lib.Diagnostics:
    diag = lib.Diagnostics()
    try:
        policy = TagPolicy.load(tag_policy)
    except PolicyError as exc:
        diag.error(str(exc))
        return diag
    loaded = lib.load_manifests(manifests)
    if not loaded:
        diag.error("no ServiceOnboarding manifests found")
    version = lib.package_version()
    seen: dict[tuple[str, str], str] = {}
    for path, doc, raw in loaded:
        source = f"{path.parent.name}/{path.name}"
        try:
            lib.check_api_version(doc, source)
        except lib.OnboardingError as exc:
            diag.error(str(exc))
            continue
        errs = lib.schema_errors(doc, lib.MANIFEST_SCHEMA)
        if errs:
            for e in errs:
                diag.error(f"{source}: {e}")
            continue
        for env in lib.manifest_envs(doc):
            if envs and env not in envs:
                continue
            key = (env, doc["metadata"]["service"])
            if key in seen:
                diag.error(f"{source}: service '{key[1]}' already onboarded for env '{env}' by {seen[key]}")
            seen[key] = source
            try:
                lib.render_manifest(doc, source, raw, env, version, policy=policy, references=None, diag=diag)
            except lib.OnboardingError as exc:
                diag.error(str(exc))
    # one notice per deprecated section kind is enough
    diag.notices = sorted(set(diag.notices))
    return diag


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifests", type=Path, nargs="+", required=True)
    ap.add_argument("--env", action="append", help="limit to env (repeatable)")
    ap.add_argument("--tag-policy", type=Path, default=None, help="tag policy YAML (default: config/tag-policy.yaml)")
    ap.add_argument("--routing", type=Path, action="append", default=[], help=argparse.SUPPRESS)
    ap.add_argument("--archetypes", type=Path, default=None, help=argparse.SUPPRESS)
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors (notices never fail)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    diag = validate(args.manifests, args.env, args.tag_policy)
    if args.routing:
        diag.notice("--routing is ignored: notification routing moved to extras/content in 3.0.0")
    if args.archetypes:
        diag.notice("--archetypes is ignored: archetypes moved to extras/content in 3.0.0")
    failed = bool(diag.errors) or (args.strict and bool(diag.warnings))
    if args.json:
        print(json.dumps({"valid": not failed, "errors": diag.errors, "warnings": diag.warnings, "notices": diag.notices}, indent=2))
    else:
        for n in diag.notices:
            print(f"NOTICE: {n}")
        for w in diag.warnings:
            print(f"WARNING: {w}")
        for e in diag.errors:
            print(f"ERROR: {e}")
        print("INVALID" if failed else "VALID", f"({len(diag.errors)} errors, {len(diag.warnings)} warnings, {len(diag.notices)} notices)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
