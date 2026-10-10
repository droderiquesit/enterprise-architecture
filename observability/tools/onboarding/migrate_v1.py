#!/usr/bin/env python3
"""Migrate ServiceOnboarding v1 manifests (2.x, monitoring content) to v2 (3.0.0: identity + tags + resources +
telemetry routing). Writes the v2 manifest; the content sections are dropped unless --keep-content (then they stay
for the optional extras/content add-on, and the core tools ignore them with a notice).

  migrate_v1.py --in manifests/prod --out manifests-v2/prod [--region westeurope] [--keep-content]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

CONTENT_SPEC = ("monitors", "notifications", "catalog", "endpoints", "slos", "idle_behavior", "dashboards")


def migrate(doc: dict, region: str | None, keep_content: bool) -> dict:
    out = {"apiVersion": "observability/v2", "kind": "ServiceOnboarding"}
    md = dict(doc["metadata"])
    if not keep_content:
        md.pop("runbook_url", None)
    if region and "region" not in md:
        md["region"] = region
    out["metadata"] = md
    spec = {k: v for k, v in doc["spec"].items() if keep_content or k not in CONTENT_SPEC}
    tel = dict(spec.get("telemetry") or {})
    if not keep_content:
        tel.pop("profile", None)
    rum = tel.get("rum")
    if isinstance(rum, dict):
        tel["rum"] = {k: v for k, v in rum.items() if k in ("enabled", "application_ref", "allowed_tracing_origins")}
    if tel:
        spec["telemetry"] = tel
    else:
        spec.pop("telemetry", None)
    for r in spec.get("resources") or []:
        if not keep_content:
            r.pop("entities", None)
    out["spec"] = spec
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--region", default=None, help="metadata.region to add where missing (tag policy key region)")
    ap.add_argument("--keep-content", action="store_true")
    args = ap.parse_args(argv)
    files = sorted(args.src.glob("*.y*ml")) if args.src.is_dir() else [args.src]
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in files:
        text = f.read_text(encoding="utf-8")
        doc = yaml.safe_load(text)
        if not isinstance(doc, dict) or doc.get("kind") != "ServiceOnboarding" or doc.get("apiVersion") != "observability/v1":
            continue
        header = "".join(line + "\n" for line in text.splitlines() if line.startswith("#"))
        new = migrate(doc, args.region, args.keep_content)
        (args.out / f.name).write_text(header + yaml.safe_dump(new, sort_keys=False, width=200), encoding="utf-8")
        n += 1
    print(f"migrated {n} manifest(s) -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
