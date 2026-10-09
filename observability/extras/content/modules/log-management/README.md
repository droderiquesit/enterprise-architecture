# modules/log-management

Datadog-side configuration for the Azure platform / control-plane logs shipped by the Fluent Bit aggregator
(`source:azure*`, `azure_log_type` tag; application categories excluded). Guide: `docs/guides/azure-logs-to-datadog.md`.

| Object | Default | Notes |
|---|---|---|
| `datadog_dashboard_json.azure_logs` "[env] Azure platform logs" | **on** | volume by source, Activity Log by category, writes/deletes by resource group, Policy denies, Key Vault 401/403, AKS exec, truncations, Activity Log failures/deletes and Service/Resource Health streams, Entra widgets with `dashboard.entra` |
| `datadog_logs_metric.this` (8) | off | `<prefix>.activity.writes`, `.activity.deletes`, `.activity.policy_denies` (by subscription_id, resource_group), `.keyvault.access_denied` (subscription_id, resource_name), `.aks.exec_portforward` (resource_name), `.entra.signin_failures` (tenant), `.volume` (source, category), `.truncated` (source). Computed on 100 % of ingested logs, before index exclusion filters. |
| `datadog_logs_index.azure` | off | filter `scope_query`, `retention_days` (15), optional `daily_limit` with warning at 80 % and reset time, `flex_retention_days`, sampled exclusion filters (default: full kube-audit get/list/watch 90 %, StorageRead 90 %, Cosmos data plane 90 %) + your own |
| `datadog_logs_index_order.this` | off | owns the **org-wide** index order |
| `datadog_logs_custom_pipeline.activity` | off | Activity Log only: `operationName`->`evt.name`, `resultType`->`evt.outcome`, `category`->`evt.category`, `callerIpAddress`->`network.client.ip`; `preserve_source = true`, `override_on_conflict = false` |
| `datadog_logs_archive.azure` | off | Azure Blob archive into an EXISTING storage account container |

## Index order (read before `index.enabled = true`)
Datadog stores each log in the **first** index whose filter matches (Datadog docs). Datadog's docs do not say where
an index created through the API is placed (checked 2026-10-09). Assume it lands **behind** existing indexes. If a
catch-all index (filter `*`, usually `main`) comes first, the new index receives nothing and its retention, quota and
exclusion filters never apply. Use one of these:
1. `index_order = { manage = true, indexes = [<every index of the org, in order>] }`. This module then owns the
   org-wide order (`PUT /api/v1/logs/config/index-order`). List every index; Datadog does not document what happens
   to unlisted ones. Use it only where this root owns the Datadog org.
2. Check and, if needed, move the index in Logs > Configuration > Indexes, once, after the first apply.

Exclusion filters exclude logs from **indexing** only. Log-based metrics, Live Tail, archives and Cloud SIEM still
see 100 %.

## Out-of-the-box pipelines
Datadog installs integration pipelines when it sees a matching `source`. The verified one is
`source:azure.activedirectory` (Entra ID; `preserveSource: true`). Pipelines for other `azure.*` sources are not
public. Enable `pipeline.enabled` only if Logs > Pipelines shows nothing that maps `operationName` / `resultType` for
the Activity Log. The package pipeline never removes or overrides attributes.

## Archive
Requires the Datadog Azure integration's Entra app (`client_id`, `tenant_id`) with Storage Blob Data Contributor on
the container. Off by default. Archived files follow the storage account's own retention; destroy removes only the
archive definition.

## Removal
Destroy removes the Datadog objects. Indexed logs follow the index retention, and archived files stay in storage.

## Tests
`tests/log_management.tftest.hcl` (mock Datadog provider): defaults create only the dashboard; everything enabled
(index filter, retention, quota, exclusions, order, metrics with bounded group-bys, preserve-source pipeline,
archive, Entra widgets); negative tests (index order without the index, archive without a target, invalid retention).

## References (checked 2026-10-09)
- https://docs.datadoghq.com/logs/log_configuration/indexes/
- https://docs.datadoghq.com/logs/log_configuration/logs_to_metrics/
- https://docs.datadoghq.com/logs/log_configuration/archives/
- https://registry.terraform.io/providers/DataDog/datadog/4.25.0/docs/resources/logs_index
- https://github.com/DataDog/integrations-core/blob/master/azure_active_directory/assets/logs/azure.activedirectory.yaml
