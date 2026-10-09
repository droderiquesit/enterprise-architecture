# Azure platform and control-plane logs in Datadog

Status (ADR-0001 §11): **implemented** and **locally-verified** (Terraform `test` with mock providers; Fluent Bit
aggregator end to end in docker against a local Kafka broker and a mock Datadog intake). Nothing here has been
**deployed** or **verified** against a live Azure subscription or Datadog organisation.

This guide covers the logs that Azure itself writes about your subscriptions and resources: the subscription
**Activity Log**, **resource logs** (Key Vault audit, AKS control plane, SQL audit, Storage, WAF, ...) and,
optionally, **Microsoft Entra ID** logs. Application logs are a separate path
([README-transport.md](../../observability/modules/README-transport.md)).

## 1. How the logs travel

```
subscription Activity Log ──(subscription diagnostic setting, modules/azure-logs)──┐
Entra ID (optional) ───────(tenant diagnostic setting,       modules/azure-logs)──┤──> Event Hub "activity-logs"
resource logs ─────────────(per-resource settings, modules/diagnostic-settings)───> Event Hub "platform-logs"
                                                                                       │ (Kafka endpoint, SASL_SSL,
                                                                                       │  consumer group fluent-bit)
                                               Fluent Bit aggregator (config/fluent-bit/aggregator.yaml)
                                               lua eh_azure_split: split batches, Datadog Azure record shape,
                                               dedup, 1 MB guard, redaction ──> Datadog logs intake (gzip, TLS)
```

| Piece | Owner (lab component) | Package module |
|---|---|---|
| `activity-logs` hub (+ consumer group) | `obs-telemetry-transport` | `modules/telemetry-transport` (`event_hub.activity_logs_hub`, default `activity-logs`; `""` shares `platform-logs`) |
| Activity Log + Entra diagnostic settings | `obs-diagnostics` | `modules/azure-logs` |
| Resource diagnostic settings (tiered categories) | `obs-diagnostics` | `modules/diagnostic-settings` (`category-policy.json`) |
| Record shaping | aggregator | `config/fluent-bit/lua/enterprise_hello.lua` (`eh_azure_split`) |
| Datadog dashboard, log-based metrics, optional index/pipeline/archive | `obs-azure-integration` | `modules/log-management` |
| Monitors | `obs-monitoring` (manifest `azure-platform-logs`) | archetype `archetypes/profiles/azure-platform-logs.yaml` |

**Why a dedicated `activity-logs` hub.** Control-plane logs are low volume but security relevant. Resource logs (HTTP
logs, storage reads, AKS API server) can burst by orders of magnitude. With separate hubs a data-plane burst cannot
fill the partitions, retention or consumer lag that audit events depend on, the subscription and tenant settings
target a fixed hub, and the hub can be given a different retention. Cost: an extra hub in an Event Hubs Standard
namespace has no hub charge (you pay throughput units and ingress events, which are the same events either way). Set
`activity_logs_hub = ""` to share the platform hub instead.

The Activity Log and Entra ID are not regional resources, so their Event Hub may be in any region of the tenant
(Microsoft: the same-region rule applies "if the resource is regional"). Resource logs must use a hub in the
resource's region; `modules/diagnostic-settings` enforces this when locations are known.

## 2. What is collected

### 2.1 Control plane

| Source | Categories | Default | ddsource in Datadog |
|---|---|---|---|
| Subscription Activity Log (`settings.activity_log`, every subscription in `subscription_ids`) | Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth (configurable) | **on** | `azure.<provider>` of the target resource (`azure.authorization`, `azure.compute`, ...), `azure.resourcegroup` for resource-group events, `azure.subscription` for subscription events (Service Health) |
| Microsoft Entra ID (`settings.entra`, tenant-wide) | AuditLogs, SignInLogs, ServicePrincipalSignInLogs, ManagedIdentitySignInLogs (default list); NonInteractiveUserSignInLogs, ProvisioningLogs, MicrosoftGraphActivityLogs, RiskyUsers, ... opt-in | **off** | `azure.activedirectory` (Datadog's Entra ID pipeline) |

### 2.2 Resource logs: tier policy

`modules/diagnostic-settings/category-policy.json` maps each resource type to categories in three cumulative tiers.
Every category was checked against Microsoft Learn's *Supported resource log categories* page for the type on
2026-10-09 (`learn_page` in the file; snapshot in `supported-categories.snapshot.json`, enforced by
`observability/tests/transport/test_category_policy.py`). At plan time the list is intersected with
`azurerm_monitor_diagnostic_categories`, so a category a resource does not offer is skipped.

| Resource type | security (audit essentials) | + standard | + verbose (high volume) |
|---|---|---|---|
| AKS `managedClusters` | kube-audit-admin, guard | kube-apiserver, cluster-autoscaler | kube-audit (replaces kube-audit-admin), kube-controller-manager, kube-scheduler, cloud-controller-manager, csi-*, karpenter-events |
| Key Vault | AuditEvent | - | AzurePolicyEvaluationDetails |
| SQL database (incl. `master` for server audit) | SQLSecurityAuditEvents, DevOpsOperationsAudit | Errors, Timeouts, Blocks, Deadlocks, AutomaticTuning | SQLInsights, QueryStore*, DatabaseWaitStatistics |
| SQL Managed Instance | SQLSecurityAuditEvents, DevOpsOperationsAudit | ResourceUsageStats | - |
| PostgreSQL flexible server | PostgreSQLLogs | PostgreSQLFlexSessions | Query Store, table stats, PgBouncer, QueryStoreSqlText |
| MySQL flexible server | MySqlAuditLogs | MySqlSlowLogs | - |
| Cosmos DB account | ControlPlaneRequests | - | DataPlaneRequests, Mongo/Cassandra/Gremlin/TableApi requests, query and partition statistics |
| Storage blob / table / queue / file services | StorageDelete | StorageWrite | StorageRead |
| Service Bus | OperationalLogs | RuntimeAuditLogs, VNetAndIPFilteringLogs, DiagnosticErrorLogs | ApplicationMetricsLogs, DataDRLogs |
| Event Hubs | OperationalLogs | RuntimeAuditLogs, DiagnosticErrorLogs, EventHubVNetConnectionEvent, KafkaUserErrorLogs, AutoScaleLogs | Kafka coordinator, archive, application metrics, CMK, DataDR |
| App Service / Functions (`sites`, `sites/slots`) | AppServiceAuditLogs, AppServiceIPSecAuditLogs, AppServiceAuthenticationLogs | AppServiceHTTPLogs, AppServicePlatformLogs | AppServiceFileAuditLogs, AppServiceAntivirusScanAuditLogs |
| Container Apps environment | - | ContainerAppSystemLogs | ContainerAppHTTPLogs, session pool logs |
| Application Gateway | ApplicationGatewayFirewallLog (WAF) | ApplicationGatewayAccessLog | ApplicationGatewayPerformanceLog |
| Front Door Std/Premium (`cdn/profiles`) | FrontDoorWebApplicationFirewallLog | FrontDoorAccessLog | FrontDoorHealthProbeLog, AzureCdnAccessLog |
| Front Door classic | FrontdoorWebApplicationFirewallLog | FrontdoorAccessLog | - |
| Azure Firewall | AZFWThreatIntel, AZFWIdpsSignature | AZFWNetworkRule, AZFWApplicationRule, AZFWNatRule, AZFWDnsQuery | flow trace, fat flow, aggregations |
| Container Registry | ContainerRegistryLoginEvents | ContainerRegistryRepositoryEvents | - |
| API Management | DeveloperPortalAuditLogs | GatewayLogs | WebSocket, LLM and MCP gateway logs |
| Batch account | AuditLog | ServiceLog | - |
| Azure Cache for Redis / Managed Redis database | MSEntraAuthenticationAuditLog / - | ConnectedClientList / ConnectionEvents | - |
| NSG | - | NetworkSecurityGroupEvent | NetworkSecurityGroupRuleCounter |
| Logic Apps (Consumption) | - | - | - (WorkflowRuntime is an application category, see README-transport.md §2.2) |

Application categories (`AppServiceConsoleLogs`, `AppServiceAppLogs`, `FunctionAppLogs`, `WorkflowRuntime`,
`ContainerAppConsoleLogs`) never appear in a tier: they go to the `app-logs` hub only for `app_log_route = eventhub`.

Defaults: the lab root `obs-diagnostics` uses `platform_log_tier = standard`. The `minimal` profile should set
`security` (see section 7). Per resource you can set `tier` or an explicit `platform_categories` list; per type,
`platform_log_allowlist_overrides`.

### 2.3 SQL audit prerequisite

`SQLSecurityAuditEvents` carries data only when auditing is enabled with the Azure Monitor target. For server-level
auditing Microsoft requires the diagnostic setting on the **master** database
(`Microsoft.Sql servers/auditingSettings`, `isAzureMonitorTargetEnabled`). `obs-diagnostics` creates that setting
(`settings.sql_server_audit`, default on). The auditing policy itself belongs to the SQL server, which
`platform-db-sql` owns, and that root does not enable it yet. This is the required platform change (not applied by
this package):

```hcl
# platform/data/sql/main.tf (platform-db-sql)
resource "azurerm_mssql_server_extended_auditing_policy" "this" {
  server_id              = azurerm_mssql_server.this.id
  enabled                = true
  log_monitoring_enabled = true   # Azure Monitor target -> the master-database diagnostic setting of obs-diagnostics
  # no storage_endpoint: audit records are streamed only through the diagnostic setting
}
```

Until that is applied, the `master` setting exists but stays empty. MySQL `MySqlAuditLogs` needs the server
parameter `audit_log_enabled = ON`, and PostgreSQL connection logging needs `log_connections` / `log_disconnections`.
Both are server parameters owned by the platform roots.

### 2.4 Not collected

* **NSG and VNet flow logs.** These are Network Watcher features written to a Storage account only; they cannot
  stream to Event Hubs. NSG flow logs retire on 2027-09-30 and no new ones can be created since 2025-06-30. The
  package does not fake this path. Options:
  1. Datadog **automated log forwarding**, which reads storage accounts (`ddlogstorage*`) with forwarders running as
     Container Apps jobs. It creates its own diagnostic settings, which conflicts with ADR rule 4.
  2. A custom blob-triggered forwarder on the flow-log storage account.

  Neither is implemented here.
* Application Insights and Log Analytics tables (no LAW data export path is configured).
* Metrics: platform metrics come from the Datadog Azure integration, never from diagnostic settings.

## 3. What a record looks like in Datadog

The aggregator keeps the Azure record **verbatim** and adds the fields Datadog's own Azure forwarder adds. The port
of `extractMetadataFromStandardLog()` from
[datadog-serverless-functions `azure/activity_logs_monitoring/index.js`](https://github.com/DataDog/datadog-serverless-functions/blob/master/azure/activity_logs_monitoring/index.js)
is in `eh_azure_split`, so Datadog's Azure integration pipelines, facets and Cloud SIEM rules see the shape they
expect.

| Field | Value |
|---|---|
| top-level Azure fields | `time`, `resourceId`, `operationName`, `category`, `resultType`, `resultSignature`, `resultDescription`, `callerIpAddress`, `correlationId`, `identity` (incl. `authorization`, `claims`), `level`, `location`, `properties` - unchanged, never flattened |
| `ddsource` | `azure.<provider namespace>` lower case (e.g. `azure.keyvault`, `azure.containerservice`, `azure.storage`); `azure.subscription` / `azure.resourcegroup` for subscription / resource-group ids; `azure.activedirectory` for Entra (`microsoft.aadiam`); `azure` without resourceId |
| `service` | `azure` (Datadog forwarder default; `FLB_AZURE_SERVICE`). Application categories keep the app's `service` |
| `ddsourcecategory` | `azure` |
| tags | `subscription_id`, `resource_group`, `tenant` (Datadog forwarder names), `resource_type`, `resource_name`, `resource_id`, `region` (resource logs with a location), `category`, `azure_log_type` (`activity` / `resource` / `entra` / `application`), `env` (record `tags.env`, else `FLB_AZURE_ENV_BY_SUBSCRIPTION`, else the aggregator's static `env`), `eventhub`, `forwarder:fluent-bit-aggregator`, `telemetry.pipeline:fluent-bit`, `truncated:true` when cut |
| `aks_audit.*` | additive copy of `verb`, `objectRef.{resource,subresource,namespace,name}`, `user.username`, `responseStatus.code`, `auditID` from the kube-audit JSON string; `properties.log` itself is untouched |
| `message` | only from non-JSON text fields (e.g. `resultDescription`, `properties.Log`); a JSON `properties.log` is never copied into `message` (the parser would lift audit fields to the top level) |

Verified convention: Datadog's Entra ID integration pipeline (`integrations-core`
`azure_active_directory/assets/logs/azure.activedirectory.yaml`) filters on `source:azure.activedirectory`, reads
`operationName`, `category`, `callerIpAddress`, `properties.*` and `level`, and remaps them with
`preserveSource: true`. Raw attributes therefore stay queryable next to `evt.name` / `evt.outcome`. The pipelines
for other `azure.*` sources are not public; the package assumes the same behaviour, so its monitors query the raw
attributes (`@operationName`, `@resultType`, `@category`).

Other aggregator behaviour:

* **Batches** `{"records":[...]}` are split into one log per entry. This covers Activity Log, Entra ID and resource
  logs.
* **Dedup.** Event Hubs is at-least-once, so a consumer-group rebalance re-reads uncommitted batches. Records with a
  strong identity (Entra `properties.id`; otherwise `time` + `resourceId` + `category` + `operationName` +
  `resultType` + `correlationId`) are delivered once (bounded FIFO cache, `FLB_AZURE_DEDUP_CACHE`, default 20000).
  Application categories that arrive on a non-app hub (for example from a hand-made portal setting) are dropped,
  because the `app-logs` path already carries them.
* **Size guard.** Datadog accepts 1 MB per log and silently truncates larger logs. Records above
  `FLB_AZURE_MAX_RECORD_BYTES` (default 900000) get their largest string fields cut, plus `truncated: true`,
  `truncated_fields` and the `truncated:true` tag. Records are never dropped. Fluent Bit's Datadog output batches
  under the 5 MB payload limit.
* **Redaction** (`eh_redact`) still masks secrets in free text and in sensitive keys, but it does not mangle Azure
  metadata. Token *type/name/status/identifier/hash* fields (`tokenIssuerType`, `uniqueTokenIdentifier`,
  `identity.tokenHash`, ...), Kubernetes `authorization.k8s.io/*` annotations, Activity Log claims such as `pwd_exp`
  and the `{"key": ..., "value": ...}` label pairs of Entra logs pass through. A pair's value is masked only when its
  label names a secret.

## 4. Cost controls

| Lever | Where |
|---|---|
| Category tier per environment / resource (`security` < `standard` < `verbose`) | `obs-diagnostics` `settings.platform_log_tier`, resource `tier`, type overrides |
| Never full `kube-audit` by default (Microsoft: `kube-audit-admin` drops get/list events); `kube-audit` replaces `kube-audit-admin` when selected | category policy `supersedes` |
| Entra: non-interactive and service-principal sign-ins can be 5-10x interactive volume (Microsoft) | `settings.entra.categories` (non-interactive is opt-in) |
| Dedicated index with retention and daily quota (warning at 80 %) | `modules/log-management` `index` (opt-in) |
| Sampled exclusion filters (90 % excluded): full kube-audit get/list/watch, StorageRead, Cosmos data plane | `index.default_exclusions`, `index.exclusion_filters` |
| Log-based metrics computed on 100 % before exclusion: activity writes/deletes, policy denies, Key Vault 401/403, AKS exec, Entra failures, volume by source/category, truncations | `modules/log-management` `metrics` |
| Event Hubs | Standard, 1 TU in the lab; ingress about USD 0.028 per million events; extra hubs free |

**Index order.** Datadog stores a log in the *first* index whose filter matches. Datadog does not document where an
index created through the API is placed, so assume it lands behind a catch-all `main` index and receives nothing.
Either let `modules/log-management` own the org-wide order (`index_order.manage = true` with every index listed)
or check and move the index in Logs > Configuration > Indexes.

## 5. Prerequisites and permissions

| What | Needed by the identity running Terraform |
|---|---|
| Resource and subscription diagnostic settings | `Microsoft.Insights/diagnosticSettings/write` on each resource / subscription (e.g. Monitoring Contributor) and `listkeys` on the Event Hubs namespace authorization rule (Manage+Send+Listen rule created by `telemetry-transport`) |
| Entra ID diagnostic setting (tenant) | Entra role **Security Administrator** (least privileged; Global Administrator also works), plus Attribute Log Administrator for `CustomSecurityAttributeAuditLogs`. **Microsoft Entra ID P1/P2** to export sign-in logs (Free exports AuditLogs; ProvisioningLogs and MicrosoftGraphActivityLogs need P1/P2). Event Hub in a subscription of the **same tenant**. Confirm with `acknowledge_prerequisites = true`; the plan fails without it. The setting is tenant-wide: enable it in **one** environment only. |
| SQL audit | platform patch in section 2.3 |
| Datadog | API + application key with log management write permissions (indexes, pipelines, metrics, archives are org-wide objects) |
| Archive (optional) | the Datadog Azure integration's Entra app has Storage Blob Data Contributor on the existing container |

## 6. Native integration alternative

`modules/azure-integration` `mode = native` can forward logs through the Azure Native Datadog resource's tag rule
(`azurerm_datadog_monitor_tag_rule` log block: `subscription_log_enabled`, `resource_log_enabled`,
`aad_log_enabled`, tag filters `native.log_tag_filters`).

| | Event Hubs + Fluent Bit (default) | Azure Native tag rule |
|---|---|---|
| Infrastructure | Event Hubs namespace + aggregator Container App | none (Microsoft-managed diagnostic settings) |
| Category control | per resource type / tier / resource | all categories of matching resources (tag include/exclude only) |
| Shaping, dedup, redaction, size guard | yes (Lua) | Datadog defaults |
| Network | private endpoint, trusted services | Microsoft-managed |
| Billing | Event Hubs + Datadog | Datadog through Azure Marketplace (MACC) |
| Diagnostic setting ownership | `obs-diagnostics` (ADR rule 4) | the Datadog resource (counts against the 5 settings per resource) |

The two paths are **mutually exclusive per source**. The following plans fail:

* `modules/azure-integration`: `eventhub_log_forwarding` overlaps native `send_subscription_logs`,
  `send_resource_logs` (per subscription) or `send_aad_logs`.
* `modules/azure-logs`: `native_log_forwarding` overlaps.
* Lab: `obs-diagnostics settings.native_log_forwarding` and `obs-azure-integration settings.native_logs` vs
  `settings.eventhub_log_forwarding`.

In the lab, native mode forwards no logs unless `settings.native_logs` is set.

## 7. Lab settings

`environments/<env>/environment.yaml` (component settings):

```yaml
obs-diagnostics:
  platform_log_tier: standard        # minimal profile: security
  sql_server_audit: true
  activity_log: {enabled: true}      # + extra_subscription_ids, categories
  entra: {enabled: false}            # tenant-wide; needs acknowledge_prerequisites: true
obs-telemetry-transport:
  event_hub_activity_logs_hub: activity-logs   # "" = share platform-logs
obs-azure-integration:
  log_management: {dashboard: true, metrics: true, index: false, pipeline: false}
  native_logs: {subscription_logs: false, resource_logs: false, aad_logs: false}
```

The monitors come from `observability/onboarding/dev/azure-platform-logs.yaml` (profile `azure-platform-logs`):
successful deletes in `eh-rg-*`, RBAC role-assignment changes, diagnostic setting deleted, Policy deny spike,
Service Health for Sweden Central, Key Vault 401/403 burst, AKS exec / port-forward / attach, Entra sign-in failures
(only when `params.entra_enabled`), and no Azure platform logs. The service is onboarded only when the
`obs-telemetry-transport` Event Hub exists (`presence_ref`). Runbook anchors:
[alerts/azure-platform-logs.md](../runbooks/alerts/azure-platform-logs.md).

## 8. Verification (after deploy)

Run in Datadog Logs (use `env:<env>`). Expected results assume activity in the window.

| Check | Query |
|---|---|
| Anything arrives | `source:azure* -azure_log_type:application` (group by `source`, `category`) |
| Activity Log | `azure_log_type:activity @category:Administrative` (perform any write, e.g. tag a resource group; latency is usually a few minutes) |
| Service / Resource Health | `azure_log_type:activity @category:(ServiceHealth OR ResourceHealth)` |
| Key Vault audit | `source:azure.keyvault @category:AuditEvent` (read a secret) |
| AKS audit | `source:azure.containerservice @category:kube-audit-admin` and `@aks_audit.verb:create` |
| Entra ID (if enabled; first data can take up to 15 minutes, Microsoft allows up to 3 days) | `source:azure.activedirectory @category:SignInLogs` |
| Datadog pipelines applied | open a log: `evt.name` / `evt.outcome` present next to `operationName` / `resultType` |
| No duplicates | `@correlationId:<id>` returns one log per step (not two) |
| No truncation | `truncated:true` should be rare; check `truncated_fields` |

Azure side: `az monitor diagnostic-settings subscription list` (Activity Log),
`az monitor diagnostic-settings list --resource <id>`, Event Hubs metrics *Incoming Messages* per hub, and the
`fluent-bit` consumer group lag.

## 9. Removal

* `obs-diagnostics` destroy, or `activity_log.enabled = false` / removing a subscription / `entra.enabled = false`,
  deletes **only** the diagnostic settings. Azure keeps its own Activity Log history (90 days) and Entra logs
  (7 or 30 days by license). Logs already in Datadog follow the index retention.
* `obs-telemetry-transport` destroys the hubs. Unconsumed events are lost; diagnostic settings must be removed first
  (the pipeline order does this).
* `modules/log-management` destroy removes the dashboard, metrics and, when enabled, index / pipeline / archive
  definitions. Datadog does not delete an index's data immediately, and archived files stay in the storage account.

## 10. References (checked 2026-10-09)

* Datadog Azure forwarder source: https://github.com/DataDog/datadog-serverless-functions/blob/master/azure/activity_logs_monitoring/index.js
* Datadog Entra ID log pipeline: https://github.com/DataDog/integrations-core/blob/master/azure_active_directory/assets/logs/azure.activedirectory.yaml
* Datadog Entra ID integration: https://docs.datadoghq.com/integrations/azure_active_directory/
* Datadog automated log forwarding: https://docs.datadoghq.com/logs/guide/azure-automated-log-forwarding/
* Datadog Event Hub log forwarding: https://docs.datadoghq.com/logs/guide/azure-event-hub-log-forwarding/
* Datadog logs API limits (1 MB per log, 5 MB payload, 1000 entries): https://docs.datadoghq.com/api/latest/logs/
* Datadog Cloud SIEM rule "Azure diagnostic setting deleted or disabled" (`@evt.name`, `@resourceId`): https://docs.datadoghq.com/security/default_rules/azure-diagnostic-setting-deleted-or-disabled
* Activity Log schema (Event Hubs format, Service Health properties): https://learn.microsoft.com/azure/azure-monitor/platform/activity-log-schema
* Diagnostic settings (regional destination rule): https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings
* Supported resource log categories: https://learn.microsoft.com/azure/azure-monitor/reference/logs-index (per-type pages in `category-policy.json`)
* Entra diagnostic settings (Security Administrator): https://learn.microsoft.com/entra/identity/monitoring-health/howto-configure-diagnostic-settings
* Entra log categories and volume note: https://learn.microsoft.com/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options and https://learn.microsoft.com/entra/identity/monitoring-health/howto-stream-logs-to-event-hub
* Entra licensing for monitoring and health: https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health
* Sign-in log export needs P1/P2 (Sentinel connector prerequisites): https://learn.microsoft.com/azure/sentinel/connect-azure-active-directory
* SQL auditing to Event Hubs / master database: https://learn.microsoft.com/azure/templates/microsoft.sql/servers/auditingsettings
* AKS resource logs (kube-audit vs kube-audit-admin): https://learn.microsoft.com/azure/aks/monitor-aks-reference
* NSG flow logs retirement and VNet flow logs: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-overview
* Azure Native integration logs and tag rules: https://learn.microsoft.com/azure/partner-solutions/metrics-logs
