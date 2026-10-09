# modules/diagnostic-settings

Creates `azurerm_monitor_diagnostic_setting` resources on **existing** resources and streams them to the
Event Hubs of `telemetry-transport`. There are at most two settings per resource, with deterministic names:

* `<prefix>-app-logs`: app-log categories, sent to the **app-logs** hub. Created only when
  `app_log_route = "eventhub"`.
* `<prefix>-platform-logs`: allow-listed platform categories, sent to the **platform-logs** hub.

Categories are always intersected with `data.azurerm_monitor_diagnostic_categories`, so a setting is created only
when at least one category remains. Resource types missing from the category maps are not queried and are
reported in `unsupported_resources`. Metrics are never exported. Removing a resource from the input deletes only
its diagnostic settings. Keys are caller-chosen and stable, so renaming a key recreates that resource's settings.

Inputs:
* `resources`: map of `{ id, app_log_route = eventhub|sidecar|daemonset|host|none, platform_logs, location, platform_categories, tier }`
* `destination`: `{ authorization_rule_id (namespace rule, Manage+Send+Listen), app_logs_hub, platform_logs_hub, location }`
* `platform_log_tier` (`security` | `standard` (default) | `verbose`), `platform_log_allowlist_overrides`
  (type -> categories, replaces the tier list for that type), `category_policy` (replace the whole policy)
* `app_log_categories`; `platform_log_allowlist` (1.0 input: when set, it replaces the policy for every type)

## Category policy (`category-policy.json`)
A maintained map: resource type -> categories per tier (cumulative), `supersedes`, a cost note and the Microsoft
Learn "supported categories" page. Every name was checked against that page on 2026-10-09; the snapshot
`supported-categories.snapshot.json` and `observability/tests/transport/test_category_policy.py` keep it honest.
Refresh both when Microsoft adds categories.

* `security`: audit essentials (Key Vault `AuditEvent`, SQL `SQLSecurityAuditEvents`, AKS `kube-audit-admin` +
  `guard`, WAF logs, Storage deletes, ...)
* `standard`: + operational logs (AKS `kube-apiserver`, App Service HTTP logs, SQL errors and deadlocks,
  `ContainerAppSystemLogs`, ...)
* `verbose`: + high-volume data-plane logs (full `kube-audit`, `StorageRead`, Cosmos `DataPlaneRequests`, ...).
  `kube-audit` supersedes `kube-audit-admin`, so audit events are never sent twice.

The per-type table with cost notes is in `docs/guides/azure-logs-to-datadog.md`. The Activity Log and Entra ID are
covered by `modules/azure-logs`. A resource equal to the destination Event Hubs namespace is skipped
(`self_referencing_resources`), because it would stream its own logs into itself.

Duplicate-prevention rules: README-transport.md §2.2–2.3.

Constraints:
* Event Hubs must be in the **same region** as the source resource. When both locations are given, a
  precondition enforces this.
* Azure allows at most 5 diagnostic settings per resource. This module uses 2.
* Event Hubs with public access denied must allow trusted Microsoft services. `telemetry-transport` configures
  this.

Tests: `tests/diagnostics.tftest.hcl` covers routes, the category intersection, unsupported types, the tiers
(cumulative, `supersedes`, per-resource tier, type overrides, the legacy allow-list), the self-referencing
namespace, and negative tests (bad route, region mismatch, hub-level rule id, unknown tier).

References:
- https://learn.microsoft.com/azure/azure-monitor/reference/logs-index (per-type pages: `learn_page` in category-policy.json)
- https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings
- https://learn.microsoft.com/azure/azure-monitor/reference/tables/containerappconsolelogs
- https://learn.microsoft.com/azure/event-hubs/private-link-service#trusted-microsoft-services
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/monitor_diagnostic_categories
