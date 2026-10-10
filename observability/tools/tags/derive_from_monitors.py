#!/usr/bin/env python3
"""Derive the tags an EXISTING Datadog organisation's monitors and SLOs depend on (read-only).

Reads every monitor (GET /api/v1/monitor, paged) and SLO (GET /api/v1/slo, paged) - never writes - and extracts each tag
key / value they filter, exclude or group on (metric scopes `{...}` and `by {...}`, log / APM / RUM / event search
queries, service-check `.over()` / `.by()`, formula variables, SLO numerator / denominator / time-slice queries) plus
the monitors' own tags. The report says which keys the package's tag policy must emit (and with which values) so the
existing monitors keep matching once telemetry flows through the package.

Keys: DD_API_KEY / DD_APP_KEY from the environment (pipelines: exported by tools/secrets/fetch.py from Delinea DSV; a
read-only application key is enough). Offline: --fixtures <dir> with monitors.json / slos.json (recorded API responses).

  derive_from_monitors.py --site datadoghq.eu --out-json required-tags.json --out-md required-tags.md
  derive_from_monitors.py --fixtures tests/tags/fixtures/org-a --policy config/tag-policy.yaml --out-json -

Exit codes: 0 ok, 2 usage / API error.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from datadog_read import ApiError, DatadogReader
from query_tags import monitor_extraction, slo_extraction
from tag_policy import TagPolicy

TOOL = "observability/tools/tags/derive_from_monitors.py"
# Tags Datadog itself or its integrations attach (Agent host tags, Kubernetes, Azure integration, APM): monitors may
# depend on them, but the package's tag policy does not emit them.
PLATFORM_KEYS = {
    "host", "device", "source", "status", "name", "subscription_id", "resource_group", "resource_id", "region", "location",
    "server_name", "statuscodecategory", "entityname", "kube_namespace", "kube_cluster_name", "kube_deployment",
    "kube_container_name", "kube_service", "kube_node", "pod_name", "container_name", "image_name", "image_tag",
    "short_image", "http.status_code", "http.method", "resource_name", "operation_name", "span.kind", "peer.service",
    "peer.db.name", "db.type", "db.instance", "availability_zone", "instance-type", "azure_log_type", "category",
    "resource_type", "tenant", "service_type", "check", "process", "monitor", "type", "telemetry.pipeline",
    # integration / check instance tags
    "db", "instance", "url", "target_host", "port", "queue", "topic", "consumer_group", "partition", "user", "schema",
    "table", "endpoint", "cluster_name", "node", "namespace", "deployment", "replica_set", "job", "cronjob",
}
UNIFIED = ("env", "service", "version")


def collect(monitors: list[dict], slos: list[dict]) -> dict:
    keys: dict[str, dict] = defaultdict(lambda: {"values": set(), "negated_values": set(), "tag_values": set(), "filtered_by": 0,
                                                 "grouped_by": 0, "monitor_tag": 0, "used_by": []})
    attributes: dict[str, dict] = defaultdict(lambda: {"values": set(), "used_by": []})
    template_vars: set[str] = set()
    unparsed = []
    for kind, items, fn in (("monitor", monitors, monitor_extraction), ("slo", slos, slo_extraction)):
        for it in items:
            ex = fn(it)
            template_vars |= ex.template_variables
            for u in ex.unparsed:
                unparsed.append({"kind": kind, "id": it.get("id"), "name": it.get("name"), "query": u})
            seen = set()
            for use in ex.uses:
                ref = {"kind": kind, "id": it.get("id"), "name": it.get("name"), "as": use.usage, "syntax": use.syntax}
                target = attributes[use.key] if use.attribute else keys[use.key]
                if use.value not in (None, "", "*"):
                    if use.usage == "negated":
                        target.setdefault("negated_values", set()).add(use.value)
                    elif use.usage == "monitor_tag":
                        target.setdefault("tag_values", set()).add(use.value)
                    else:
                        target["values"].add(use.value)
                if not use.attribute:
                    if use.usage in ("filter", "negated", "over", "exclude"):
                        target["filtered_by"] += 1
                    elif use.usage == "group_by":
                        target["grouped_by"] += 1
                    else:
                        target["monitor_tag"] += 1
                dedupe = (use.key, use.usage, it.get("id"))
                if dedupe not in seen:
                    seen.add(dedupe)
                    target["used_by"].append(ref)
    return {"keys": keys, "attributes": attributes, "template_variables": sorted(template_vars), "unparsed": unparsed}


def classify(key: str, policy: TagPolicy | None) -> str:
    if policy is not None:
        canon = policy.canonical_for(key)
        if canon is not None:
            return f"policy:{canon}" + ("" if policy.primary(canon) == key else " (alias)")
        if key in (policy.doc.get("static_tags") or {}):
            return "policy:static"
    if key in PLATFORM_KEYS or key.startswith(("kube_", "azure.", "aws_", "dd.")):
        return "platform"
    return "unmapped"


def report(monitors: list[dict], slos: list[dict], policy: TagPolicy | None, source: str) -> dict:
    c = collect(monitors, slos)
    keys = {}
    for k in sorted(c["keys"]):
        d = c["keys"][k]
        keys[k] = {
            "values": sorted(d["values"]), "negated_values": sorted(d.get("negated_values", set())),
            "monitor_tag_values": sorted(d.get("tag_values", set())),
            "filtered_by": d["filtered_by"], "grouped_by": d["grouped_by"], "monitor_tag": d["monitor_tag"],
            "monitors_and_slos": len({(u["kind"], u["id"]) for u in d["used_by"]}),
            "classification": classify(k, policy),
            "used_by": sorted(d["used_by"], key=lambda u: (u["kind"], str(u["id"]), u["as"])),
        }
    # required = keys monitors/SLOs FILTER or GROUP on (monitor_tag-only keys are ownership metadata, not matching)
    required = sorted(k for k, d in keys.items() if (d["filtered_by"] or d["grouped_by"]) and d["classification"] != "platform")
    suggestions = []
    for k in required:
        cls = keys[k]["classification"]
        if cls == "unmapped":
            alias_of = [o for o, d in keys.items() if o != k and d["classification"].startswith("policy:") and keys[k]["values"]
                        and set(keys[k]["values"]) <= set(d["values"])]
            if alias_of:
                suggestions.append({"key": k, "values": keys[k]["values"],
                                    "suggestion": f"same values as '{alias_of[0]}': add '{k}' as an alias of '{alias_of[0]}' in the tag policy"})
            else:
                suggestions.append({"key": k, "values": keys[k]["values"],
                                    "suggestion": "add to the tag policy: a new key, an alias of an existing key, or a static tag"})
        elif policy is not None and cls.startswith("policy:") and not cls.startswith("policy:static"):
            canon = cls.split(":", 1)[1].split(" ")[0]
            vm = {str(a).lower() for a in (policy.keys[canon].get("value_map") or {}).values()}
            for v in keys[k]["values"]:
                if any(ch in v for ch in "*?"):
                    continue
                if policy.normalize and v != v.lower():
                    suggestions.append({"key": k, "value": v, "suggestion": "monitor filters a mixed-case value; Datadog lowercases tags - check the monitor"})
                if k == "env" and v in ("production", "development", "staging") and v not in vm:
                    suggestions.append({"key": k, "value": v, "suggestion": f"emit env:{v} (value_map) or align the monitors"})
    return {
        "tool": TOOL, "source": source,
        "monitors_scanned": len(monitors), "slos_scanned": len(slos),
        "required_keys": required,
        "keys": keys,
        "attributes": {k: {"values": sorted(v["values"]), "used_by": len(v["used_by"])} for k, v in sorted(c["attributes"].items())},
        "template_variables": c["template_variables"],
        "unparsed": c["unparsed"],
        "suggestions": suggestions,
    }


def markdown(rep: dict) -> str:
    lines = ["# Tags required by the existing monitors and SLOs", "",
             f"Source: `{rep['source']}` - {rep['monitors_scanned']} monitors, {rep['slos_scanned']} SLOs (read-only).", "",
             "| Key | Classification | Values used | Filter / group / tag uses | Monitors + SLOs |", "|---|---|---|---|---|"]
    for k, d in rep["keys"].items():
        shown = d["values"] or d["monitor_tag_values"]
        suffix = "" if d["values"] else (" (monitor tags)" if shown else "")
        vals = ", ".join(f"`{v}`" for v in shown[:8]) + (" ..." if len(shown) > 8 else "") + suffix
        neg = (" (excluded: " + ", ".join(f"`{v}`" for v in d["negated_values"][:4]) + ")") if d["negated_values"] else ""
        uses = f"{d['filtered_by']} / {d['grouped_by']} / {d['monitor_tag']}"
        lines.append(f"| `{k}` | {d['classification']} | {vals or '-'}{neg} | {uses} | {d['monitors_and_slos']} |")
    required = ", ".join(f"`{k}`" for k in rep["required_keys"]) or "-"
    lines += ["", f"Required keys (filtered or grouped on, not platform-provided): {required}", ""]
    if rep["suggestions"]:
        lines += ["## Suggestions for the tag policy", ""]
        lines += [f"- `{s['key']}`{(' = `' + s['value'] + '`') if 'value' in s else ''}: {s['suggestion']}" for s in rep["suggestions"]]
        lines.append("")
    if rep["unparsed"]:
        lines += ["## Queries not parsed (review by hand)", ""]
        lines += [f"- {u['kind']} {u['id']} {u['name']}: `{u['query']}`" for u in rep["unparsed"]]
        lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", default="datadoghq.com")
    ap.add_argument("--fixtures", type=Path, help="offline: directory with monitors.json / slos.json API responses")
    ap.add_argument("--policy", type=Path, help="tag policy to classify keys against (default: package config/tag-policy.yaml)")
    ap.add_argument("--no-policy", action="store_true")
    ap.add_argument("--out-json", default="required-tags.json", help="'-' = stdout")
    ap.add_argument("--out-md", default=None)
    args = ap.parse_args(argv)
    try:
        reader = DatadogReader(args.site, fixtures=args.fixtures)
        monitors, slos = reader.monitors(), reader.slos()
    except ApiError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    policy = None if args.no_policy else TagPolicy.load(args.policy)
    rep = report(monitors, slos, policy, str(args.fixtures) if args.fixtures else f"api.{args.site}")
    text = json.dumps(rep, indent=2, sort_keys=True) + "\n"
    if args.out_json == "-":
        sys.stdout.write(text)
    else:
        Path(args.out_json).write_text(text, encoding="utf-8")
    if args.out_md:
        Path(args.out_md).write_text(markdown(rep), encoding="utf-8")
    print(f"{rep['monitors_scanned']} monitors, {rep['slos_scanned']} SLOs -> required keys: {', '.join(rep['required_keys'])}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
