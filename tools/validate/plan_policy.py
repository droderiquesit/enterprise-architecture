#!/usr/bin/env python3
"""Plan policy on `terraform show -json <plan>` output.

    python3 tools/validate/plan_policy.py --plan plan.json --component platform-db-sql --env dev \
        [--summary-md summary.md] [--summary-json summary.json] [--approvals environments/dev/approvals.yaml]

Fails (exit 1) when the plan deletes or replaces a resource of a PROTECTED type (state-bearing or
foundational: databases, storage, Key Vault, networks, registries, clusters, identities ...) unless an
unexpired entry in environments/<env>/approvals.yaml `allow_destroy` matches the component and the
resource address (glob). Flags cost-relevant changes (creation of expensive types, SKU/size/capacity
changes) as warnings. Writes a human-readable summary (no attribute values, so no secrets).
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import sys
from pathlib import Path

import yaml

PROTECTED_TYPES = {
    "azurerm_resource_group", "azurerm_key_vault", "azurerm_storage_account", "azurerm_storage_container",
    "azurerm_storage_table", "azurerm_mssql_server", "azurerm_mssql_database", "azurerm_mssql_elasticpool",
    "azurerm_mssql_managed_instance", "azurerm_mssql_managed_database", "azurerm_mssql_virtual_machine",
    "azurerm_postgresql_flexible_server", "azurerm_postgresql_flexible_server_database",
    "azurerm_mysql_flexible_server", "azurerm_mysql_flexible_database",
    "azurerm_cosmosdb_account", "azurerm_cosmosdb_sql_database", "azurerm_cosmosdb_sql_container",
    "azurerm_cosmosdb_mongo_database", "azurerm_cosmosdb_mongo_collection", "azurerm_cosmosdb_cassandra_keyspace",
    "azurerm_cosmosdb_gremlin_database", "azurerm_cosmosdb_table", "azurerm_mongo_cluster",
    "azurerm_cosmosdb_postgresql_cluster", "azurerm_managed_redis", "azurerm_cassandra_cluster",
    "azurerm_confidential_ledger", "azurerm_kusto_cluster", "azurerm_kusto_database", "azurerm_synapse_workspace",
    "azurerm_search_service", "azurerm_virtual_network", "azurerm_subnet", "azurerm_private_dns_zone",
    "azurerm_log_analytics_workspace", "azurerm_container_registry", "azurerm_kubernetes_cluster",
    "azurerm_servicebus_namespace", "azurerm_eventhub_namespace", "azurerm_user_assigned_identity",
    "azurerm_managed_disk", "azurerm_recovery_services_vault", "azurerm_service_fabric_managed_cluster",
    "azurerm_redhat_openshift_cluster", "azurerm_batch_account",
}
COST_CREATE_TYPES = {
    "azurerm_firewall", "azurerm_application_gateway", "azurerm_mssql_managed_instance", "azurerm_kubernetes_cluster",
    "azurerm_kubernetes_cluster_node_pool", "azurerm_managed_redis", "azurerm_cosmosdb_account",
    "azurerm_linux_virtual_machine", "azurerm_windows_virtual_machine", "azurerm_linux_virtual_machine_scale_set",
    "azurerm_windows_virtual_machine_scale_set", "azurerm_orchestrated_virtual_machine_scale_set",
    "azurerm_virtual_network_gateway", "azurerm_bastion_host", "azurerm_nat_gateway", "azurerm_kusto_cluster",
    "azurerm_synapse_workspace", "azurerm_synapse_spark_pool", "azurerm_synapse_sql_pool", "azurerm_dedicated_host",
    "azurerm_service_fabric_managed_cluster", "azurerm_redhat_openshift_cluster", "azurerm_batch_pool",
    "azurerm_cdn_frontdoor_profile", "azurerm_api_management", "azurerm_cassandra_datacenter",
    "azurerm_machine_learning_compute_cluster", "azurerm_search_service", "azurerm_mssql_elasticpool",
}
COST_ATTRIBUTES = {"sku", "sku_name", "sku_tier", "vm_size", "size", "node_count", "min_count", "max_count",
                   "capacity", "instances", "zone_redundant", "storage_mb", "max_size_gb", "throughput",
                   "max_throughput", "storage_quota_in_gb", "high_availability", "tier", "vcores"}


def _actions(rc: dict) -> list[str]:
    return list(rc.get("change", {}).get("actions", []))


def classify(actions: list[str]) -> str:
    if actions == ["no-op"] or actions == ["read"]:
        return "no-op"
    if "delete" in actions and "create" in actions:
        return "replace"
    if actions == ["delete"]:
        return "delete"
    if actions == ["create"]:
        return "create"
    if actions == ["update"]:
        return "update"
    if actions == ["forget"]:
        return "forget"
    return "+".join(actions)


def changed_attributes(rc: dict) -> set[str]:
    before = rc.get("change", {}).get("before") or {}
    after = rc.get("change", {}).get("after") or {}
    if not isinstance(before, dict) or not isinstance(after, dict):
        return set()
    return {k for k in set(before) | set(after) if before.get(k) != after.get(k)}


def load_approvals(path: Path | None, component: str, today: dt.date) -> list[dict]:
    if not path or not path.exists():
        return []
    doc = yaml.safe_load(path.read_text()) or {}
    out = []
    for a in doc.get("allow_destroy") or []:
        if a.get("component") != component:
            continue
        try:
            expires = dt.date.fromisoformat(str(a.get("expires_on")))
        except ValueError:
            continue
        if expires >= today:
            out.append(a)
    return out


def evaluate(plan: dict, component: str, approvals: list[dict]) -> dict:
    changes, violations, approved, cost = [], [], [], []
    for rc in plan.get("resource_changes", []):
        if rc.get("mode") == "data":
            continue
        kind = classify(_actions(rc))
        if kind == "no-op":
            continue
        addr, typ = rc.get("address"), rc.get("type")
        changes.append({"address": addr, "type": typ, "action": kind})
        if kind in ("delete", "replace") and typ in PROTECTED_TYPES:
            match = next((a for a in approvals if any(fnmatch.fnmatchcase(addr, p) for p in a.get("addresses", []))), None)
            entry = {"address": addr, "type": typ, "action": kind}
            if match:
                entry["approved_by"] = match.get("approved_by")
                approved.append(entry)
            else:
                violations.append(entry)
        if kind == "create" and typ in COST_CREATE_TYPES:
            cost.append({"address": addr, "type": typ, "reason": "creates a cost-relevant resource"})
        elif kind in ("update", "replace"):
            attrs = sorted(changed_attributes(rc) & COST_ATTRIBUTES)
            if attrs:
                cost.append({"address": addr, "type": typ, "reason": "changes " + ", ".join(attrs)})
    counts = {}
    for c in changes:
        counts[c["action"]] = counts.get(c["action"], 0) + 1
    return {"component": component, "counts": counts, "changes": changes, "violations": violations,
            "approved_destroys": approved, "cost_flags": cost, "has_changes": bool(changes),
            "drift": bool(plan.get("resource_drift"))}


def to_markdown(r: dict) -> str:
    lines = [f"# Plan summary: {r['component']}", ""]
    if not r["changes"]:
        lines.append("No changes.")
    else:
        lines.append("| action | count |\n|---|---|")
        lines += [f"| {k} | {v} |" for k, v in sorted(r["counts"].items())]
        lines += ["", "| action | address |", "|---|---|"]
        lines += [f"| {c['action']} | `{c['address']}` |" for c in r["changes"]]
    if r["violations"]:
        lines += ["", "## BLOCKED: protected resources would be deleted/replaced", ""]
        lines += [f"- `{v['address']}` ({v['action']})" for v in r["violations"]]
        lines.append("\nAdd an approved, unexpired `allow_destroy` entry to environments/<env>/approvals.yaml to proceed.")
    if r["approved_destroys"]:
        lines += ["", "## Approved destructive changes", ""]
        lines += [f"- `{v['address']}` ({v['action']}), approved by {v['approved_by']}" for v in r["approved_destroys"]]
    if r["cost_flags"]:
        lines += ["", "## Cost-relevant changes", ""]
        lines += [f"- `{c['address']}`: {c['reason']}" for c in r["cost_flags"]]
    if r["drift"]:
        lines += ["", "Terraform detected changes made outside Terraform (resource_drift)."]
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--env", default="dev")
    ap.add_argument("--approvals")
    ap.add_argument("--summary-md")
    ap.add_argument("--summary-json")
    ap.add_argument("--today", help="YYYY-MM-DD (tests)")
    args = ap.parse_args(argv)
    plan = json.loads(Path(args.plan).read_text())
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    approvals_path = Path(args.approvals) if args.approvals else Path(f"environments/{args.env}/approvals.yaml")
    result = evaluate(plan, args.component, load_approvals(approvals_path, args.component, today))
    md = to_markdown(result)
    if args.summary_md:
        Path(args.summary_md).parent.mkdir(parents=True, exist_ok=True)
        Path(args.summary_md).write_text(md)
    if args.summary_json:
        Path(args.summary_json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.summary_json).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(md)
    for c in result["cost_flags"]:
        print(f"##vso[task.logissue type=warning]cost-relevant change: {c['address']}: {c['reason']}")
    if result["violations"]:
        for v in result["violations"]:
            print(f"##vso[task.logissue type=error]protected resource {v['action']}: {v['address']} (no approval)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
