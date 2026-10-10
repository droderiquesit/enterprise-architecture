#!/usr/bin/env python3
"""Render ServiceOnboarding v2 manifests into per-service JSON (identity, tag set, resources, telemetry routing).

Subcommands
  render      manifests -> <out>/<service>.json   (add --check to verify committed output)
  references  flatten a contracts directory into a Terraform tfvars file {"contract_references": {...}}

The tag set comes from the tag policy (--tag-policy, default config/tag-policy.yaml), exactly as modules/tagging renders
it in Terraform. Committed output is rendered WITHOUT --contracts-dir (${contract:...} references stay verbatim, so CI
can prove it is current with --check); --contracts-dir resolves references in Python (unresolved optional resources
are dropped with a warning, unresolved required ones fail).

Exit codes: 0 ok, 1 manifest error or --check drift, 2 usage error.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import onboarding_lib as lib
from tag_policy import TagPolicy


def render_all(manifests: list[Path], env: str, contracts_dir: Path | None, policy: TagPolicy,
               diag: lib.Diagnostics) -> dict[str, str]:
    refs = lib.flatten_contracts(contracts_dir) if contracts_dir else None
    version = lib.package_version()
    outputs: dict[str, str] = {}
    for path, doc, raw in lib.load_manifests(manifests):
        source = f"{path.parent.name}/{path.name}"
        lib.check_api_version(doc, source)
        errs = lib.schema_errors(doc, lib.MANIFEST_SCHEMA)
        if errs:
            raise lib.OnboardingError(f"{source}: schema errors:\n  " + "\n  ".join(errs))
        if env not in lib.manifest_envs(doc) or not doc["spec"].get("enabled", True):
            continue
        result = lib.render_manifest(doc, source, raw, env, version, policy=policy, references=refs, diag=diag)
        fname = f"{result.service}.json"
        if fname in outputs:
            raise lib.OnboardingError(f"{source}: service '{result.service}' rendered twice for env {env}")
        outputs[fname] = lib.dump_json(result.data)
    return outputs


def cmd_render(args: argparse.Namespace) -> int:
    diag = lib.Diagnostics()
    if args.archetypes is not None:
        diag.notice("--archetypes is ignored: archetypes (monitor content) moved to extras/content in 3.0.0")
    try:
        policy = TagPolicy.load(args.tag_policy)
        outputs = render_all(args.manifests, args.env, args.contracts_dir, policy, diag)
    except (lib.OnboardingError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for n in diag.notices:
        print(f"NOTICE: {n}", file=sys.stderr)
    for w in diag.warnings:
        print(f"WARNING: {w}", file=sys.stderr)
    if diag.errors:
        for e in diag.errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1
    out = Path(args.out)
    if args.check:
        existing = {p.name: p.read_text(encoding="utf-8") for p in out.glob("*.json")} if out.exists() else {}
        drift = sorted(set(existing) ^ set(outputs)) + sorted(
            n for n in set(existing) & set(outputs) if existing[n] != outputs[n])
        if drift:
            print(f"ERROR: rendered output in {out} is stale for: {', '.join(drift)}\n"
                  f"       re-run: render.py render --env {args.env} ... --out {out}", file=sys.stderr)
            return 1
        print(f"OK: {len(outputs)} rendered services in {out} are up to date")
        return 0
    out.mkdir(parents=True, exist_ok=True)
    for stale in out.glob("*.json"):
        if stale.name not in outputs:
            stale.unlink()
    for name, text in outputs.items():
        (out / name).write_text(text, encoding="utf-8")
    print(f"rendered {len(outputs)} services for env '{args.env}' -> {out}")
    return 0


def cmd_references(args: argparse.Namespace) -> int:
    refs = lib.flatten_contracts(args.contracts_dir)
    text = lib.dump_json({"contract_references": refs})
    if args.out == "-":
        sys.stdout.write(text)
    else:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"wrote {len(refs)} references -> {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render", help="render manifests")
    r.add_argument("--manifests", type=Path, nargs="+", required=True, help="manifest files or directories")
    r.add_argument("--env", required=True)
    r.add_argument("--out", type=Path, required=True)
    r.add_argument("--tag-policy", type=Path, default=None, help="tag policy YAML (default: config/tag-policy.yaml)")
    r.add_argument("--contracts-dir", type=Path, default=None)
    r.add_argument("--archetypes", type=Path, default=None, help=argparse.SUPPRESS)
    r.add_argument("--check", action="store_true", help="fail if --out differs from a fresh render")
    r.set_defaults(func=cmd_render)
    f = sub.add_parser("references", help="flatten contracts into contract_references tfvars")
    f.add_argument("--contracts-dir", type=Path, required=True)
    f.add_argument("--out", default="-")
    f.set_defaults(func=cmd_references)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
