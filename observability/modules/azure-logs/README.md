# modules/azure-logs

Azure **control-plane** logs of EXISTING subscriptions and tenants -> Event Hubs (normally the `activity-logs` hub of
`modules/telemetry-transport`). The Fluent Bit aggregator ships them to Datadog in the shape of Datadog's own Azure
forwarder (`ddsource` `azure.<provider>` / `azure.subscription` / `azure.activedirectory`, `service:azure`).
Guide: `docs/guides/azure-logs-to-datadog.md`.

| Resource | When | Scope |
|---|---|---|
| `azurerm_monitor_diagnostic_setting.activity_log[<subscription>]` | `activity_log.enabled` (default) | `target_resource_id = /subscriptions/<id>` (Activity Log), one per `activity_log.subscription_ids` entry |
| `azurerm_monitor_aad_diagnostic_setting.entra[0]` | `entra.enabled` (default **false**) | the Entra tenant of the provider (tenant-wide) |

Inputs:
* `activity_log`: `{ enabled, subscription_ids (GUIDs), categories (default all 8: Administrative, Security,
  ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth), setting_name }`
* `entra`: `{ enabled, acknowledge_prerequisites, categories (default AuditLogs, SignInLogs,
  ServicePrincipalSignInLogs, ManagedIdentitySignInLogs), setting_name, eventhub_name, authorization_rule_id }`
* `destination`: `{ authorization_rule_id (namespace rule, Manage+Send+Listen), eventhub_name }`
* `native_log_forwarding`: what the Azure Native integration already forwards (`subscription_log_subscription_ids`,
  `aad_logs`), usually `modules/azure-integration` output `native_log_forwarding`. The plan fails on overlap.

Outputs: `activity_log_settings`, `activity_log_categories`, `entra_setting_id`, `log_forwarding` (input for
`modules/azure-integration` `eventhub_log_forwarding`).

## Prerequisites
* `Microsoft.Insights/diagnosticSettings/write` on every subscription (e.g. Monitoring Contributor) and `listkeys` on
  the namespace authorization rule.
* Entra ID (validated: `enabled` requires `acknowledge_prerequisites = true`):
  * the identity running Terraform is **Security Administrator** (least privileged; Attribute Log Administrator in
    addition for `CustomSecurityAttributeAuditLogs`);
  * **Microsoft Entra ID P1/P2** to export sign-in logs (`ProvisioningLogs` and `MicrosoftGraphActivityLogs` need
    P1/P2 too);
  * the Event Hubs namespace is in a subscription of the same tenant.

  The setting is tenant-wide: create it in one root only. Non-interactive and service-principal sign-ins can be 5-10x
  the interactive volume.
* Region: the Activity Log and Entra ID are not regional resources, so Microsoft's same-region rule for Event Hub
  destinations does not apply.

## Removal
Removing a subscription, `activity_log.enabled = false`, `entra.enabled = false` or destroy deletes **only** the
diagnostic settings. Azure keeps its own Activity Log (90 days) and Entra history.

## Tests
`tests/azure_logs.tftest.hcl`: one setting per subscription with all categories, disable, Entra with
acknowledgement, and negative tests (Entra without acknowledgement, unknown Entra / Activity Log category, resource
id instead of a GUID, overlap with native subscription logs, overlap with native Entra logs).

## References (checked 2026-10-09)
- https://learn.microsoft.com/azure/azure-monitor/platform/activity-log-schema
- https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings
- https://learn.microsoft.com/entra/identity/monitoring-health/howto-configure-diagnostic-settings
- https://learn.microsoft.com/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options
- https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_aad_diagnostic_setting
