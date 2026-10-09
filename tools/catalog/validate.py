#!/usr/bin/env python3
"""Validate the Azure service catalog.

Checks
  * every catalog/services/*.yaml against catalog/schemas/service.schema.json (JSON Schema 2020-12)
  * unique ids; parent ids exist
  * every catalog_refs id in catalog/components.yaml and every architectures/databases key in
    catalog/architecture-matrix.yaml exists in the catalog
  * iac.component refers to a component in catalog/components.yaml
  * >= 1 https reference per entry; Datadog doc reference for live database/compute/serverless entries
  * status/lifecycle consistency (retired/retiring => not a default; blocked => reason; implemented/disabled => component;
    default_profiles consistent with environments/profiles; live validation needs evidence)
  * catalog/provider-gaps.yaml <-> iac.azapi consistency
  * catalog/telemetry-capabilities.yaml covers every architecture and database family
  * optional --check-provider: terraform_resources exist in azurerm 5.9.0 (needs `tfschema` on PATH)

Usage: python3 tools/catalog/validate.py [--check-provider] [--quiet]
Exit code 1 on any error.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from catalog_lib import (  # noqa: E402
    GAPS_PATH, MATRIX_PATH, REPO_ROOT, SCHEMA_PATH, TELEMETRY_PATH, all_entries, load_components,
    load_profiles, load_service_files, load_yaml,
)

try:
    import jsonschema
except ImportError:  # pragma: no cover
    print("ERROR: python package 'jsonschema' is required (pip install jsonschema)", file=sys.stderr)
    sys.exit(2)

LIVE_CATEGORIES = {"database", "compute", "serverless"}
NOT_DEFAULT_LIFECYCLES = {"retired", "retiring", "not-recommended"}
COMPUTE_SIGNALS = ["app_logs", "traces", "app_metrics", "runtime_metrics", "platform_metrics", "platform_logs", "dbm", "rum", "profiling"]
DB_SIGNALS = ["platform_metrics", "platform_logs", "client_spans", "dbm"]
SIGNAL_FIELDS = ["supported", "method", "owner", "duplicate_prevention", "datadog_limitation"]


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def validate_schema(docs: dict, rep: Report) -> None:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)
    for name, doc in docs.items():
        for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path)):
            path = "/".join(str(p) for p in err.absolute_path)
            ident = ""
            if len(err.absolute_path) >= 2 and err.absolute_path[0] == "services":
                try:
                    ident = f" [{doc['services'][err.absolute_path[1]].get('id')}]"
                except (IndexError, KeyError, TypeError, AttributeError):
                    pass
            rep.error(f"{name}{ident}: schema: {path}: {err.message}")


def validate_entries(entries: list[tuple[str, dict]], rep: Report) -> dict[str, dict]:
    components = {c["id"]: c for c in load_components()}
    profiles = load_profiles()
    by_id: dict[str, dict] = {}
    for fname, e in entries:
        eid = e.get("id")
        if eid in by_id:
            rep.error(f"{fname}: duplicate id {eid!r}")
        by_id[eid] = e

    for fname, e in entries:
        eid = e.get("id", "?")
        where = f"{fname} [{eid}]"
        lc = (e.get("lifecycle") or {}).get("status")
        st = e.get("status") or {}
        impl = st.get("implementation")
        iac = e.get("iac") or {}
        comp = iac.get("component")
        defaults = st.get("default_profiles") or []

        if e.get("parent") and e["parent"] not in by_id:
            rep.error(f"{where}: parent {e['parent']!r} does not exist")
        if comp is not None and comp not in components:
            rep.error(f"{where}: iac.component {comp!r} not in catalog/components.yaml")

        refs = e.get("references") or []
        if not any(r.startswith("https://") for r in refs):
            rep.error(f"{where}: needs at least one https reference")
        if (e.get("category") in LIVE_CATEGORIES and lc not in ("retired",)
                and not any("docs.datadoghq.com" in r for r in refs)):
            rep.error(f"{where}: {e.get('category')} entry needs a docs.datadoghq.com reference")

        # lifecycle / status consistency
        if lc in ("retired", "retiring") and not (e.get("lifecycle") or {}).get("retirement_date"):
            rep.error(f"{where}: lifecycle {lc} requires lifecycle.retirement_date")
        if lc == "retired":
            if impl not in ("cataloged", "blocked"):
                rep.error(f"{where}: retired service must be cataloged or blocked, not {impl}")
            if iac.get("implemented"):
                rep.error(f"{where}: retired service cannot have iac.implemented = true")
        if lc in NOT_DEFAULT_LIFECYCLES and defaults:
            rep.error(f"{where}: lifecycle {lc} must not be in any default profile (default_profiles={defaults})")
        if impl == "blocked" and not st.get("blocked_reason"):
            rep.error(f"{where}: implementation blocked requires status.blocked_reason")
        if impl != "blocked" and st.get("blocked_reason"):
            rep.warn(f"{where}: blocked_reason set but implementation is {impl}")
        if impl in ("implemented", "disabled"):
            if not iac.get("implemented"):
                rep.error(f"{where}: implementation {impl} requires iac.implemented = true")
            if comp is None:
                rep.error(f"{where}: implementation {impl} requires iac.component")
            elif comp in components:
                refs_c = set(components[comp].get("catalog_refs") or [])
                if refs_c and eid not in refs_c and e.get("parent") not in refs_c:
                    rep.warn(f"{where}: not listed in catalog_refs of component {comp}")
        elif iac.get("implemented"):
            rep.error(f"{where}: iac.implemented = true but implementation is {impl}")
        if impl in ("disabled", "cataloged", "blocked") and defaults:
            rep.error(f"{where}: implementation {impl} must have empty default_profiles")
        if impl == "implemented" and comp in components:
            expected = sorted(p for p, comps in profiles.items() if comp in comps)
            if sorted(defaults) != expected:
                rep.error(f"{where}: default_profiles {sorted(defaults)} != profiles enabling {comp} {expected}")
        if st.get("live_validation") in ("deployed", "verified"):
            ev = st.get("evidence")
            if not ev or not (REPO_ROOT / ev).exists():
                rep.error(f"{where}: live_validation {st.get('live_validation')} requires an existing status.evidence file")
            if impl not in ("implemented", "disabled"):
                rep.error(f"{where}: live_validation {st.get('live_validation')} requires implementation implemented/disabled")
        if (e.get("lifecycle") or {}).get("successor") and lc in ("ga", "preview"):
            rep.warn(f"{where}: successor set on a {lc} service")
    return by_id


def validate_references(by_id: dict[str, dict], rep: Report) -> None:
    for comp in load_components():
        for ref in comp.get("catalog_refs") or []:
            if ref not in by_id:
                rep.error(f"catalog/components.yaml: component {comp['id']} catalog_ref {ref!r} has no catalog entry")
    matrix = load_yaml(MATRIX_PATH)
    for section in ("architectures", "databases"):
        for key in (matrix.get(section) or {}):
            if key not in by_id:
                rep.error(f"catalog/architecture-matrix.yaml: {section}.{key} has no catalog entry")


def validate_gaps(by_id: dict[str, dict], rep: Report) -> None:
    doc = load_yaml(GAPS_PATH) or {}
    gaps = doc.get("gaps") or []
    seen: dict[str, dict] = {}
    for g in gaps:
        sid = g.get("service_id")
        where = f"provider-gaps.yaml [{sid}]"
        if sid in seen:
            rep.error(f"{where}: duplicate service_id")
        seen[sid] = g
        if sid not in by_id:
            rep.error(f"{where}: service_id not in catalog")
        if g.get("resolution") not in ("azapi", "not-iac-deployable", "other-provider"):
            rep.error(f"{where}: invalid resolution {g.get('resolution')!r}")
        if not g.get("reason"):
            rep.error(f"{where}: reason required")
        if not any(str(r).startswith("https://") for r in g.get("references") or []):
            rep.error(f"{where}: needs an https reference")
        if g.get("resolution") == "azapi" and not g.get("arm_types"):
            rep.error(f"{where}: azapi resolution needs arm_types")
        e = by_id.get(sid)
        if e is not None:
            declared = {(a["type"], a["api_version"]) for a in (e.get("iac") or {}).get("azapi") or []}
            listed = {(t["type"], str(t["api_version"])) for t in g.get("arm_types") or []}
            if g.get("resolution") == "azapi" and declared != listed:
                rep.error(f"{where}: arm_types {sorted(listed)} != catalog iac.azapi {sorted(declared)}")
    for sid, e in by_id.items():
        if (e.get("iac") or {}).get("azapi") and sid not in seen:
            rep.error(f"catalog [{sid}]: uses azapi but has no entry in catalog/provider-gaps.yaml")


def validate_telemetry(by_id: dict[str, dict], rep: Report) -> None:
    doc = load_yaml(TELEMETRY_PATH) or {}
    matrix = load_yaml(MATRIX_PATH)
    compute = doc.get("compute") or {}
    dbs = doc.get("databases") or {}
    for key in matrix.get("architectures") or {}:
        if key not in compute:
            rep.error(f"telemetry-capabilities.yaml: compute.{key} missing (architecture-matrix key)")
    expected_db = set(matrix.get("databases") or {}) | {
        i for i, e in by_id.items() if e.get("category") == "database" and (e.get("lifecycle") or {}).get("status") != "retired"}
    for key in sorted(expected_db):
        if key not in dbs:
            rep.error(f"telemetry-capabilities.yaml: databases.{key} missing")
    for section, keys, sigs in (("compute", compute, COMPUTE_SIGNALS), ("databases", dbs, DB_SIGNALS)):
        for key, val in keys.items():
            where = f"telemetry-capabilities.yaml {section}.{key}"
            ref = (val or {}).get("catalog_ref")
            if ref not in by_id:
                rep.error(f"{where}: catalog_ref {ref!r} not in catalog")
            signals = (val or {}).get("signals") or {}
            for s in sigs:
                if s not in signals:
                    rep.error(f"{where}: signal {s} missing")
                    continue
                for f in SIGNAL_FIELDS:
                    if f not in signals[s]:
                        rep.error(f"{where}.{s}: field {f} missing")
                if signals[s].get("supported") not in ("yes", "no", "partial", "n/a"):
                    rep.error(f"{where}.{s}: invalid supported value {signals[s].get('supported')!r}")
                if signals[s].get("supported") in ("yes", "partial") and not signals[s].get("owner"):
                    rep.error(f"{where}.{s}: supported signal needs an owner component")


def validate_provider(entries: list[tuple[str, dict]], rep: Report) -> None:
    exe = shutil.which("tfschema")
    if not exe:
        rep.warn("--check-provider: tfschema not on PATH; skipped")
        return
    out = subprocess.run([exe, "list", "azurerm_.*"], capture_output=True, text=True, check=False).stdout.split()
    known = set(out)
    if not known:
        rep.warn("--check-provider: tfschema returned nothing; skipped")
        return
    for fname, e in entries:
        for r in (e.get("iac") or {}).get("terraform_resources") or []:
            if r not in known:
                rep.error(f"{fname} [{e.get('id')}]: terraform resource {r} not in azurerm 5.9.0 schema")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check-provider", action="store_true", help="verify terraform_resources with tfschema")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    rep = Report()
    docs = load_service_files()
    if not docs:
        print("ERROR: no catalog/services/*.yaml files", file=sys.stderr)
        return 1
    validate_schema(docs, rep)
    entries = all_entries(docs)
    by_id = validate_entries(entries, rep)
    validate_references(by_id, rep)
    validate_gaps(by_id, rep)
    validate_telemetry(by_id, rep)
    if args.check_provider:
        validate_provider(entries, rep)

    for w in rep.warnings:
        if not args.quiet:
            print(f"WARN  {w}")
    for e in rep.errors:
        print(f"ERROR {e}")
    status = "FAILED" if rep.errors else "OK"
    print(f"catalog validation {status}: {len(entries)} entries in {len(docs)} files, "
          f"{len(rep.errors)} error(s), {len(rep.warnings)} warning(s)")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
