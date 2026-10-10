# lab/diagnostics (component `obs-diagnostics`)

**Owner:** observability. **Purpose:** the only owner of diagnostic settings in the lab (ADR §3 rule 4). It wraps
`modules/diagnostic-settings` (resource logs, tiered category policy) and `modules/azure-logs` (subscription
Activity Log, optional Entra ID). Guide: [azure-logs-to-datadog.md](../../../docs/guides/azure-logs-to-datadog.md).

* **Consumes:**
  * `obs_telemetry_transport` (`event_hub.*` incl. optional `activity_logs_hub`, `fluentbit.aca_console_allow`)
  * `discovered_contracts`
  * `resources`
* **Produces:** no contract. Outputs (`discovered_targets`, `app_log_settings`, `platform_log_settings`,
  `platform_log_tiers`, `excluded_app_log_resources`, `aca_eventhub_apps`, `unsupported_resources`,
  `activity_log_settings`, `entra_setting_id`, `control_plane_log_forwarding`) are deployment evidence.

## Resource discovery (no state reads)
`tools/contracts/materialize.py` passes `discovered_contracts`: a map of contract name to data, covering every
enabled `platform-*` and `deploy-*` component (`discovers_resources: true` in `catalog/components.yaml`).
`discovery.tf` extracts targets with an **explicit map**; there is no recursion:

| Contract path | Target | Route |
|---|---|---|
| `deploy-*.apps.<k>` with type `Microsoft.Web/sites[/slots]` or `Microsoft.Logic/workflows` | the app | as published (`eventhub` sends AppServiceConsoleLogs/AppLogs/FunctionAppLogs/WorkflowRuntime to the app-logs hub) |
| `deploy-*.apps.<k>` with type `Microsoft.App/containerApps` or `Microsoft.App/jobs` | folded into the **Container Apps environment** (`contract.environment_id`, else `platform-containerapps.environment_id`) | environment = `eventhub` only if some app or job in it is `eventhub` (normally jobs, which have no sidecar), else `sidecar` |
| `deploy-*` Kubernetes/Deployment, VMs, ACI, Static Web Apps | none | other collectors |
| `platform-containerapps.environment_id` | environment | as above |
| `platform-db-sql.server.id` + `/databases/master` (`settings.sql_server_audit`) | the master database | `none`, categories `SQLSecurityAuditEvents`, `DevOpsOperationsAudit` (server-level audit) |
| `platform-aks.cluster_id`, `platform-messaging.namespace_id`, `platform-shared.acr_id`, `platform-db-{postgresql,mysql,sqlmi}.server.id`, `platform-db-sql.databases.<k>.id`, `platform-db-cosmos-*.account.id`, `platform-db-redis.cache.id`, `platform-batch.account_id` | the resource | `none` (platform categories only) |

The explicit `resources` map (same shape as before) is merged last and wins.
The `check` `aca_console_allow_covers_eventhub_apps` warns when an Event Hub route ACA app or job is missing
from the aggregator allow-list, because its console logs would be dropped.

## Settings
* `setting_name_prefix` (default `datadog-obs`): settings are named `<prefix>-app-logs` and
  `<prefix>-platform-logs`.
* `platform_log_tier` (default `standard`; set `security` in the minimal profile, see section 7 of the guide)
* `platform_log_allowlist_overrides`: replaces the tier list of a resource type
* `sql_server_audit` (default true): diagnostic setting on `<server>/databases/master`. Events flow only after
  `platform-db-sql` enables server auditing with the Azure Monitor target (patch in the guide, section 2.3).
* `activity_log`: `{ enabled = true, categories (all 8), extra_subscription_ids }`. The environment subscription is
  always included.
* `entra`: `{ enabled = false, acknowledge_prerequisites, categories }`. This is TENANT-wide: enable it in one
  environment only. It needs Security Administrator for the pipeline identity and Entra ID P1/P2 for sign-in logs.
* `native_log_forwarding`: mirror of `obs-azure-integration` `native_logs`. Validation rejects native subscription
  logs + Activity Log export, native Entra + Entra export, and native resource logs (which would duplicate every
  setting of this root).

## Cost
Diagnostic settings are free. Event Hubs ingress events are about $0.03 per million. The Datadog log ingestion
volume grows with the tier: `security` < `standard` < `verbose`. The Activity Log of a lab subscription is typically
a few thousand events per day.

## Teardown
Destroy removes only the diagnostic settings (resource, subscription Activity Log and, if enabled, the tenant Entra
setting). Resources and Azure's own log history are untouched.

## Private networking
Streaming to Event Hubs uses the trusted-services exception. The Event Hub must be in the resource's region,
which a precondition enforces when locations are known.

## Limitations
* Resource types missing from the allow-lists are skipped (`unsupported_resources`).
* Managed Redis (`Microsoft.Cache/redisEnterprise`) and DocumentDB (Mongo clusters) categories are not
  allow-listed yet.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/control_plane.tftest.hcl`, `tests/discovery.tftest.hcl`, `tests/lab.tftest.hcl`. From the repository root: `python3 tools/validate/all_terraform.py --only obs-diagnostics` (fmt, validate, test).
