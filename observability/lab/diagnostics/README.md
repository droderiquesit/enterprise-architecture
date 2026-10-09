# lab/diagnostics (component `obs-diagnostics`)

**Owner:** observability. **Purpose:** the only owner of diagnostic settings in the lab (ADR §3 rule 4). It wraps
`modules/diagnostic-settings`.

* **Consumes:**
  * `obs_telemetry_transport` (`event_hub.*`, `fluentbit.aca_console_allow`)
  * `discovered_contracts`
  * `resources`
* **Produces:** no contract. Outputs (`discovered_targets`, `app_log_settings`, `platform_log_settings`,
  `excluded_app_log_resources`, `aca_eventhub_apps`, `unsupported_resources`) are deployment evidence.

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
| `platform-aks.cluster_id`, `platform-messaging.namespace_id`, `platform-shared.acr_id`, `platform-db-{postgresql,mysql,sqlmi}.server.id`, `platform-db-sql.databases.<k>.id`, `platform-db-cosmos-*.account.id`, `platform-db-redis.cache.id`, `platform-batch.account_id` | the resource | `none` (platform categories only) |

The explicit `resources` map (same shape as before) is merged last and wins.
The `check` `aca_console_allow_covers_eventhub_apps` warns when an Event Hub route ACA app or job is missing
from the aggregator allow-list, because its console logs would be dropped.

## Settings
* `setting_name_prefix` (default `datadog-obs`): settings are named `<prefix>-app-logs` and
  `<prefix>-platform-logs`.
* `platform_log_allowlist_overrides`

## Cost
Diagnostic settings are free. Event Hubs ingress events are about $0.03 per million. The Datadog log ingestion
volume grows with the categories you enable.

## Teardown
Destroy removes only the diagnostic settings. Resources and history are untouched.

## Private networking
Streaming to Event Hubs uses the trusted-services exception. The Event Hub must be in the resource's region,
which a precondition enforces when locations are known.

## Limitations
* Resource types missing from the allow-lists are skipped (`unsupported_resources`).
* Managed Redis (`Microsoft.Cache/redisEnterprise`) and DocumentDB (Mongo clusters) categories are not
  allow-listed yet.
