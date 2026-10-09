#!/usr/bin/env python3
"""Validate onboarding manifests, archetypes and notification routing (schema + semantic checks).

Semantic checks
  * every manifest renders (archetype merge, templates, thresholds, SLO rules)
  * unique service per env; unique resource roles / endpoint names per manifest
  * literal resource ids are well-formed ARM ids (references are allowed)
  * every route key used by a manifest exists in the routing file of that env (when --routing is given)
  * every rendered monitor has a runbook link, a non-empty notification route, a numeric critical threshold
    whose value appears in the query, and a team tag
  * monitor overrides / disabled entries reference existing monitor keys (warning)
  * public endpoints without synthetics, and always-on services without a no-data guard (warning)

Exit codes: 0 valid (warnings allowed unless --strict), 1 invalid, 2 usage error.
Output: human text, or JSON with --json.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import onboarding_lib as lib  # noqa: E402


def validate(manifests: list[Path], archetypes_dir: Path, envs: list[str] | None, routing: list[Path]) -> lib.Diagnostics:
    diag = lib.Diagnostics()
    try:
        archetypes = lib.ArchetypeSet.load(archetypes_dir, diag)
    except lib.OnboardingError as exc:
        diag.error(str(exc))
        return diag

    routes_by_env: dict[str, set[str]] = {}
    for rp in routing:
        doc = lib.load_yaml(rp)
        for e in lib.schema_errors(doc, "notification-routing.v1.schema.json"):
            diag.error(f"{rp.name}: {e}")
        if isinstance(doc, dict) and "metadata" in doc and "routes" in doc:
            routes_by_env[doc["metadata"]["env"]] = set(doc["routes"])

    loaded = lib.load_manifests(manifests)
    if not loaded:
        diag.error("no ServiceOnboarding manifests found")
    version = lib.package_version()
    seen: dict[tuple[str, str], str] = {}
    for path, doc, raw in loaded:
        source = f"{path.parent.name}/{path.name}"
        errs = lib.schema_errors(doc, "onboarding-manifest.v1.schema.json")
        if errs:
            for e in errs:
                diag.error(f"{source}: {e}")
            continue
        spec = doc["spec"]
        names = [e["name"] for e in spec.get("endpoints", [])]
        if len(names) != len(set(names)):
            diag.error(f"{source}: duplicate endpoint names {names}")
        for env in lib.manifest_envs(doc):
            if envs and env not in envs:
                continue
            key = (env, doc["metadata"]["service"])
            if key in seen:
                diag.error(f"{source}: service '{key[1]}' already onboarded for env '{env}' by {seen[key]}")
            seen[key] = source
            try:
                result = lib.render_manifest(doc, source, raw, archetypes, env, version, None, diag)
            except lib.OnboardingError as exc:
                diag.error(str(exc))
                continue
            _semantic(source, doc, result.data, routes_by_env.get(env), diag)
    return diag


def _semantic(source: str, doc: dict, data: dict, routes: set[str] | None, diag: lib.Diagnostics) -> None:
    used_routes: set[str] = set()
    for key, mon in data["monitors"].items():
        where = f"{source}: monitor {key}"
        if "Runbook: http" not in mon["message"] or not mon["runbook_url"].startswith("http"):
            diag.error(f"{where}: message lacks a runbook link")
        if not mon["notify"]["alert"]:
            diag.error(f"{where}: no notification route for severity '{mon['severity']}'")
        used_routes.update(mon["notify"]["alert"])
        used_routes.update(mon["notify"]["warning"])
        crit = lib._fmt(mon["thresholds"]["critical"])
        if mon["type"] in ("query alert", "metric alert", "log alert", "rum alert") and not mon["query"].rstrip().endswith(crit):
            diag.error(f"{where}: query threshold does not equal thresholds.critical ({crit}): {mon['query']}")
        if not any(t.startswith("team:") for t in mon["tags"]):
            diag.error(f"{where}: missing team tag")
    for slo in data["slos"]:
        for b in slo["burn_rate_alerts"]:
            used_routes.update(b["notify"]["alert"])
            if not b["notify"]["alert"]:
                diag.error(f"{source}: SLO {slo['name']} burn-rate alert has no route")
    if routes is not None:
        missing = sorted(used_routes - routes)
        if missing:
            diag.error(f"{source}: notification route keys not defined for env '{data['env']}': {missing}")
    for ov in (doc["spec"].get("monitors") or {}).get("overrides", {}) or {}:
        base = ov.split("@")[0]
        if not any(k == ov or k.split("@")[0] == base for k in data["monitors"]):
            diag.warn(f"{source}: override '{ov}' does not match a rendered monitor (disabled or unknown?)")
    for ep in data["endpoints"]:
        if ep["visibility"] == "public" and not ep["synthetic"].get("enabled"):
            diag.warn(f"{source}: public endpoint '{ep['name']}' has no synthetic test")
    if not data["idle_behavior"]["scale_to_zero"] and data["telemetry"]["traces"].get("enabled"):
        if not any(m["notify_no_data"] or "no_traffic" in k for k, m in data["monitors"].items()):
            diag.warn(f"{source}: always-on service without a missing-telemetry monitor")


def main(argv: list[str] | None = None) -> int:
    pkg = lib.PACKAGE_ROOT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifests", type=Path, nargs="+", required=True)
    ap.add_argument("--archetypes", type=Path, default=pkg / "archetypes")
    ap.add_argument("--env", action="append", help="limit to env (repeatable)")
    ap.add_argument("--routing", type=Path, action="append", default=[], help="notification routing file(s)")
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    diag = validate(args.manifests, args.archetypes, args.env, args.routing)
    failed = bool(diag.errors) or (args.strict and bool(diag.warnings))
    if args.json:
        print(json.dumps({"valid": not failed, "errors": diag.errors, "warnings": diag.warnings}, indent=2))
    else:
        for w in diag.warnings:
            print(f"WARNING: {w}")
        for e in diag.errors:
            print(f"ERROR: {e}")
        print("INVALID" if failed else "VALID", f"({len(diag.errors)} errors, {len(diag.warnings)} warnings)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
