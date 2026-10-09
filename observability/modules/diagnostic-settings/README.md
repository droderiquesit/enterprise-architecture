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
* `resources`: map of `{ id, app_log_route = eventhub|sidecar|daemonset|host|none, platform_logs, location, platform_categories }`
* `destination`: `{ authorization_rule_id (namespace rule, Manage+Send+Listen), app_logs_hub, platform_logs_hub, location }`
* `app_log_categories`, `platform_log_allowlist`: maps keyed by lower-case resource type

Duplicate-prevention rules: README-transport.md §2.2–2.3.

Constraints:
* Event Hubs must be in the **same region** as the source resource. When both locations are given, a
  precondition enforces this.
* Azure allows at most 5 diagnostic settings per resource. This module uses 2.
* Event Hubs with public access denied must allow trusted Microsoft services. `telemetry-transport` configures
  this.

Tests: `tests/diagnostics.tftest.hcl` covers routes, the category intersection, unsupported types, and negative
tests (bad route, region mismatch, hub-level rule id).

References:
- https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings
- https://learn.microsoft.com/azure/azure-monitor/reference/tables/containerappconsolelogs
- https://learn.microsoft.com/azure/event-hubs/private-link-service#trusted-microsoft-services
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/monitor_diagnostic_categories
