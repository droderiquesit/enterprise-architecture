# modules/azure-integration

Datadog ↔ Azure integration for **existing** tenants and subscriptions. The module has three modes:

| mode | Resources | When to use it |
|---|---|---|
| `app_registration` (default) | `datadog_integration_azure`, plus a `Monitoring Reader` role assignment on each subscription for the app's service principal (optional) | Standard pull integration: metrics, resource collection, automute, tag filters. One integration per tenant + app covers every subscription the app can read. |
| `native` | `azurerm_datadog_monitor` (new and linked to an existing org, or `existing_monitor_id`), `azurerm_datadog_monitor_tag_rule` (metric and log tag filters), and AzAPI `Microsoft.Datadog/monitors/monitoredSubscriptions@2025-06-11` for additional subscriptions | Azure Native ISV integration (marketplace resource) |
| `none` | nothing | Integration managed elsewhere |

Inputs: `tenant_id`, `subscription_ids`, `metric_tag_filters` (Include / Exclude, which become Datadog
`host_filters` such as `application:enterprise-hello,!datadog:exclude`), and `settings` (automute,
custom_metrics, resource_collection, cspm, usage_metrics, app_service_plan and container_app filters).
`app_registration = { client_id, auth = secret|secretless, service_principal_object_id }`.
Output: `integration_id`, which is the integration id (`<tenant>:<client>`) or the monitor resource id.

## Secrets
* `auth = secretless` is the **default** (no secret anywhere). `client_secret` (auth = secret only) is a sensitive input the
  pipeline reads from Delinea DSV just in time (never tfvars). The module never outputs it.
  `datadog_integration_azure.client_secret` is stored (encrypted) in state. This is a provider limitation: there
  is no write-only variant in datadog 4.25.
* `auth = secretless` uses Datadog's secretless (workload identity federation) auth, so no secret is involved.
  You must create the federated credential on the Entra app as Datadog documents it. azurerm cannot manage Entra
  objects, so the lab does this in `bootstrap/`.
* Linking a **new** native monitor requires `native_org_keys` (API + application key, sensitive, kept in state).
  Prefer `existing_monitor_id`.

## Log forwarding: native tag rule vs Event Hubs
`mode = native` can forward logs itself (`native.send_subscription_logs` (default true), `send_resource_logs`
(default false), `send_aad_logs` (default false), `log_tag_filters` Include/Exclude). Azure then creates and owns
diagnostic settings on matching resources. The Event Hubs path (`modules/azure-logs`, `modules/diagnostic-settings`,
Fluent Bit aggregator) gives per-category control, record shaping, dedup and a size guard, but needs Event Hubs and
the aggregator. The native path needs no infrastructure and is billed through the Azure Marketplace.

**Pick one path per source.** Pass what the Event Hubs path exports as `eventhub_log_forwarding`
(`activity_log_subscription_ids`, `resource_log_subscription_ids`, `entra_enabled`). The plan fails when a native
toggle overlaps it for the same subscription or tenant. Output `native_log_forwarding` feeds
`modules/azure-logs` `native_log_forwarding` for the reverse check. Trade-offs: `docs/guides/azure-logs-to-datadog.md`
section 6.

## Duplicate prevention
* Native `resource_log_enabled` defaults to **false**. When true, Azure creates its own diagnostic settings per
  resource, which duplicates the Event Hub, sidecar and DaemonSet routes (README-transport.md §2.5).
* Datadog **automated log forwarding** (ARM template: control-plane Function Apps, forwarders on Container Apps
  jobs plus storage, and diagnostic settings created automatically on discovered resources) is not used for the
  same reason. It also conflicts with ADR rule 4, which says diagnostic settings are owned by obs-diagnostics.
  The Event Hub path is implemented in `telemetry-transport` + `diagnostic-settings`. Datadog now labels its
  own legacy Event Hub forwarder "existing deployments only". This package's Event Hub consumer is Fluent Bit,
  not Datadog's Function forwarder.

## Known limitations
* `resource_provider_configs` (per-namespace metric switches) is not wired. With datadog provider 4.25,
  `terraform validate` fails when that list comes from a variable (framework unknown-value bug). Use tag filters
  instead.
* AzAPI gap: `Microsoft.Datadog/monitors/monitoredSubscriptions` (API 2025-06-11) has no azurerm resource.

## Tests
`tests/integration.tftest.hcl` covers app_registration, secretless, native new and existing monitors, `none`, the
native log block (subscription, resource and Entra logs, tag filters), and negative tests (secret mode without a
secret, bad subscription id, native + Event Hubs Activity Log on the same subscription, native resource logs +
diagnostic settings, native + Event Hubs Entra).

## References (checked 2026-10-09)
- https://docs.datadoghq.com/integrations/guide/azure-programmatic-management
- https://docs.datadoghq.com/integrations/guide/azure-portal (Azure Native integration)
- https://docs.datadoghq.com/logs/guide/azure-automated-log-forwarding/ and https://docs.datadoghq.com/logs/guide/azure-automated-logs-architecture
- https://docs.datadoghq.com/integrations/guide/azure-advanced-configuration/
- https://learn.microsoft.com/azure/templates/microsoft.datadog/2025-06-11/monitors/monitoredsubscriptions
- https://registry.terraform.io/providers/DataDog/datadog/4.25.0/docs/resources/integration_azure
- https://learn.microsoft.com/azure/partner-solutions/metrics-logs (native tag rules for logs)
