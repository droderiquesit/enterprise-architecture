#!/usr/bin/env python3
"""Tag coverage: do the tags this configuration emits satisfy the tag policy and the existing monitors / SLOs?

Static (always): renders nothing new - reads the committed onboarding output (tools/onboarding render, rendered/<env>/*.json:
the exact tag set modules/tagging applies to every path of a service and its resources) and compares it with
  * the tag policy (config/tag-policy.yaml or --policy): every required key present on every service / resource
  * optional requirements from tools/tags/derive_from_monitors.py (--requirements): every key the existing monitors /
    SLOs filter or group on is emitted, and every value they filter on is a value some service emits
    (e.g. monitors filter env:production while the services emit env:prod -> value mismatch)
Live (--live, read-only): for every rendered service, Datadog log and span search over the last --minutes minutes
(POST .../events/search, read-only) and host tags (GET /api/v1/hosts): services without data, events missing policy
keys, events whose values differ from the rendered tag set.

Keys: DD_API_KEY / DD_APP_KEY from the environment (pipelines: tools/secrets/fetch.py from Delinea DSV); --fixtures
<dir> replays recorded API responses offline.

Output: JSON (--out-json) + Markdown (--out-md). Exit codes: 0 no required gap, 1 required gaps, 2 usage / API error.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from datadog_read import ApiError, DatadogReader
from tag_policy import UNIFIED, TagPolicy, parse_tag

TOOL = "observability/tools/tags/check_coverage.py"


def load_rendered(dirs: list[Path], env: str | None) -> list[dict]:
    docs = []
    for d in dirs:
        for f in sorted(Path(d).glob("*.json")):
            doc = json.loads(f.read_text(encoding="utf-8"))
            if doc.get("schema") != "rendered-service/v2":
                raise ValueError(f"{f}: not a rendered-service/v2 document (render with tools/onboarding/render.py)")
            if env is None or doc.get("env") == env:
                docs.append(doc)
    return docs


def static_gaps(policy: TagPolicy, services: list[dict], requirements: dict | None) -> tuple[list[dict], list[dict]]:
    gaps, infos = [], []
    version_keys = set(policy.dd_keys("version")) if "version" in policy.keys else {"version"}
    required = [k for k in policy.required_keys() if k not in version_keys]  # version is set at deploy time
    for svc in services:
        for k in required:
            if k not in svc["tags"]:
                gaps.append({"type": "missing_policy_key", "required": True, "service": svc["service"], "env": svc["env"], "key": k})
        for r in svc.get("resources", []):
            for k in required:
                if k not in r.get("tags", {}):
                    gaps.append({"type": "missing_policy_key", "required": True, "service": svc["service"], "env": svc["env"],
                                 "resource": r["role"], "key": k})
    if requirements:
        emitted: dict[str, set[str]] = {}
        for svc in services:
            for src in [svc["tags"], *[r.get("tags", {}) for r in svc.get("resources", [])]]:
                for k, v in src.items():
                    emitted.setdefault(k, set()).add(v)
        for k in requirements.get("required_keys", []):
            info = requirements["keys"].get(k, {})
            if k in version_keys:
                continue
            if k not in emitted:
                gaps.append({"type": "missing_monitor_key", "required": True, "key": k, "monitors_and_slos": info.get("monitors_and_slos"),
                             "values": info.get("values", []), "used_by": [u["name"] for u in info.get("used_by", [])][:10],
                             "fix": "add the key to the tag policy (canonical key, alias or static tag)"})
                continue
            wanted = [v for v in info.get("values", []) if not any(ch in v for ch in "*?")]
            unmatched = sorted(v for v in wanted if policy.norm(v) not in emitted[k])
            if unmatched:
                # required when NO monitor value matches (e.g. env:production vs env:prod everywhere); partial overlap =
                # monitors for services / teams this configuration does not onboard (informational)
                gaps.append({"type": "value_mismatch", "required": len(unmatched) == len(wanted), "key": k, "monitor_values": unmatched,
                             "emitted_values": sorted(emitted[k]),
                             "used_by": [u["name"] for u in info.get("used_by", [])][:10],
                             "fix": f"value_map in the tag policy (e.g. {k}: {{<emitted>: {unmatched[0]}}}) or align the monitors"})
        for k, info in (requirements.get("keys") or {}).items():
            if info.get("classification") == "platform" and (info.get("filtered_by") or info.get("grouped_by")):
                infos.append({"type": "platform_key", "key": k, "note": "provided by Datadog / integrations (not the tag policy)"})
    return gaps, infos


def _event_tags(attrs: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for t in attrs.get("tags") or []:
        k, v = parse_tag(str(t))
        if v is not None:
            out.setdefault(k, set()).add(v)
    for k in UNIFIED:
        if attrs.get(k):
            out.setdefault(k, set()).add(str(attrs[k]))
    return out


def live_gaps(reader: DatadogReader, policy: TagPolicy, services: list[dict], minutes: int, require_data: bool) -> tuple[list[dict], dict]:
    gaps = []
    now = datetime.now(UTC)
    frm = (now - timedelta(minutes=minutes)).isoformat()
    observed = {}
    version_keys = set(policy.dd_keys("version")) if "version" in policy.keys else {"version"}
    required = policy.required_keys()
    for svc in services:
        q = f"service:{svc['service']} env:{svc['tags'].get('env', svc['env'])}"
        events = []
        for path, kind in (("/api/v2/logs/events/search", "log"), ("/api/v2/spans/events/search", "span")):
            body = {"filter": {"query": q, "from": frm, "to": now.isoformat()}, "page": {"limit": 25}}
            if kind == "span":
                body = {"data": {"type": "search_request", "attributes": body}}
            doc = reader.request("POST", path, body=body)
            for e in (doc or {}).get("data") or []:
                events.append((kind, e))
        observed[svc["service"]] = len(events)
        if not events:
            if svc.get("telemetry", {}).get("apm_mode") != "none" or svc.get("telemetry", {}).get("logs_route") != "none":
                gaps.append({"type": "no_data", "required": require_data, "service": svc["service"], "env": svc["env"],
                             "window_minutes": minutes, "query": q})
            continue
        for kind, e in events:
            attrs = e.get("attributes") or {}
            present = _event_tags(attrs)
            missing = [k for k in required if k not in present]
            mismatch = {k: sorted(present[k]) for k, v in svc["tags"].items()
                        if k in present and k not in version_keys and v not in present[k]}
            if missing or mismatch:
                gaps.append({"type": "observed_tag_gap", "required": True, "service": svc["service"], "signal": kind,
                             "event_id": e.get("id"), "missing": missing, "mismatched": mismatch})
                break  # one example per service and signal kind is enough
    hosts = reader.request("GET", "/api/v1/hosts", {"filter": f"env:{services[0]['env']}" if services else "", "count": 100})
    host_report = []
    for h in (hosts or {}).get("host_list") or []:
        tags = {parse_tag(t)[0] for src in (h.get("tags_by_source") or {}).values() for t in src}
        missing = [k for k in required if k not in tags and k not in ("service", "version")]
        host_report.append({"host": h.get("name"), "missing_policy_keys": missing})
        if missing:
            gaps.append({"type": "host_tag_gap", "required": False, "host": h.get("name"), "missing": missing})
    return gaps, {"events_per_service": observed, "hosts": host_report}


def markdown(rep: dict) -> str:
    lines = ["# Datadog tag coverage", "",
             f"Policy: `{rep['policy']}` - {rep['services_checked']} services ({', '.join(rep['envs']) or '-'}); "
             f"requirements: `{rep['requirements'] or '-'}`; live: {rep['live']}.", "",
             f"Result: **{'FAIL' if rep['required_gaps'] else 'PASS'}** ({rep['required_gaps']} required gaps, "
             f"{len(rep['gaps']) - rep['required_gaps']} other).", ""]
    if rep["gaps"]:
        lines += ["| Type | Required | Where | Key(s) | Detail |", "|---|---|---|---|---|"]
        for g in rep["gaps"]:
            where = g.get("service") or g.get("host") or "-"
            if g.get("resource"):
                where += f" / {g['resource']}"
            keys = g.get("key") or ", ".join(g.get("missing", []) or list(g.get("mismatched", {})))
            detail = g.get("fix") or ""
            if g["type"] == "value_mismatch":
                detail = f"monitors filter {g['monitor_values']}, emitted {g['emitted_values']}; {g['fix']}"
            elif g["type"] == "no_data":
                detail = f"nothing in the last {g['window_minutes']} min for `{g['query']}`"
            elif g["type"] == "observed_tag_gap":
                detail = f"{g['signal']} {g.get('event_id')}: missing {g['missing']} mismatched {g['mismatched']}"
            req = "yes" if g.get("required") else "no"
            lines.append(f"| {g['type']} | {req} | {where} | {keys or '-'} | {detail} |")
        lines.append("")
    if rep["info"]:
        lines += ["Platform-provided keys the monitors use (not emitted by the tag policy): " +
                  ", ".join(f"`{i['key']}`" for i in rep["info"]), ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rendered", type=Path, action="append", required=True, help="rendered onboarding dir (repeatable)")
    ap.add_argument("--env", default=None)
    ap.add_argument("--policy", type=Path, default=None)
    ap.add_argument("--requirements", type=Path, default=None, help="derive_from_monitors.py JSON")
    ap.add_argument("--live", action="store_true", help="also query Datadog (read-only)")
    ap.add_argument("--site", default="datadoghq.com")
    ap.add_argument("--fixtures", type=Path, default=None, help="offline API responses for --live")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--require-data", action="store_true", help="services without data are required gaps")
    ap.add_argument("--out-json", default="tag-coverage.json", help="'-' = stdout")
    ap.add_argument("--out-md", default=None)
    args = ap.parse_args(argv)
    try:
        policy = TagPolicy.load(args.policy)
        services = load_rendered(args.rendered, args.env)
        requirements = json.loads(args.requirements.read_text(encoding="utf-8")) if args.requirements else None
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    gaps, infos = static_gaps(policy, services, requirements)
    live = None
    if args.live:
        try:
            reader = DatadogReader(args.site, fixtures=args.fixtures)
            lg, live = live_gaps(reader, policy, services, args.minutes, args.require_data)
            gaps += lg
        except ApiError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
    rep = {
        "tool": TOOL, "policy": str(args.policy or "config/tag-policy.yaml"),
        "requirements": str(args.requirements) if args.requirements else None,
        "envs": sorted({s["env"] for s in services}), "services_checked": len(services), "live": bool(args.live),
        "required_gaps": sum(1 for g in gaps if g.get("required")), "gaps": gaps, "info": infos, "observed": live,
    }
    text = json.dumps(rep, indent=2, sort_keys=True) + "\n"
    if args.out_json == "-":
        sys.stdout.write(text)
    else:
        Path(args.out_json).write_text(text, encoding="utf-8")
    if args.out_md:
        Path(args.out_md).write_text(markdown(rep), encoding="utf-8")
    print(f"{rep['services_checked']} services: {rep['required_gaps']} required gaps, {len(gaps) - rep['required_gaps']} other", file=sys.stderr)
    return 1 if rep["required_gaps"] else 0


if __name__ == "__main__":
    sys.exit(main())
