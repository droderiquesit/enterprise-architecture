# Analytics data stores (platform-data-analytics)

- **Component id:** `platform-data-analytics` (catalog/components.yaml; catalog refs: `data-explorer`, `synapse-sql`, `synapse-spark`, `ai-search`, `blob-storage`, `adls-gen2`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Toggleable analytics stores for the hello-dbadapter families:

| Store | Default | Boundary | Adapter RBAC |
|---|---|---|---|
| Blob storage account | on | container `adapter` | Storage Blob Data Contributor (container) |
| ADLS Gen2 (HNS) account | on | filesystem `adapter` | Storage Blob Data Contributor (filesystem) |
| Azure Data Explorer `Dev(No SLA)_Standard_E2a_v4`, auto-stop | off | database `adapter` (1 d hot cache, 7 d retention) / table `Records` (ARM `kusto_script`) | database roles User + Ingestor |
| Azure AI Search `basic` | off | index `adapter-records` (created by the app) | Search Index Data Contributor + Search Service Contributor |
| Synapse workspace | off (matrix: cataloged-only) | ADLS filesystem `adapter` as default storage | none (workspace MI gets Blob Data Contributor on ADLS) |

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-data-analytics` v1 — schema `catalog/contracts/platform-data-analytics.v1.schema.json` (output `contract`, no secrets).
One object per store (`null` when disabled) with id, endpoint, boundary, owner identity, auth mode and private endpoint IDs; `dbm.supported = false`.

## Settings (`components.platform-data-analytics` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `private_endpoints_enabled` | `true` |
| `blob.{enabled,replication_type}` | `true`, `LRS` |
| `adls.{enabled,replication_type}` | `true`, `LRS` |
| `data_explorer.{enabled,sku_name,capacity,auto_stop_enabled,hot_cache_period,soft_delete_period}` | `false`, `Dev(No SLA)_Standard_E2a_v4`, 1, `true`, `P1D`, `P7D` |
| `search.{enabled,sku,replica_count,partition_count}` | `false`, `basic`, 1, 1 |
| `synapse.{enabled,entra_admin}` | `false`, — (requires ADLS) |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Defaults ~USD 25: two storage accounts (< 2) + three private endpoints (blob, ADLS dfs + blob ≈ 22). ADX dev ~USD 120-150 while running (auto-stops after 5 idle days); AI Search basic ~USD 75; Synapse workspace pay-per-use (serverless SQL per TB).

## Private networking
All stores have public network access disabled. PEs: blob (`blob`), ADLS (`dfs` + `blob`), ADX (`cluster`; zones `kusto`, `blob`, `queue`, `table`), Search (`searchService`, zone `search`), Synapse (`Sql`, no zone key in foundation-network v1 ⇒ created without DNS zone group). The AI Search **free** tier has no private endpoint support and is rejected while private endpoints are on.

## Authentication and data-plane access
Storage: shared key disabled, Entra RBAC. ADX: Entra database principal assignments (app = hello-dbadapter client ID). Search: local (API key) auth disabled, Entra RBAC. Synapse: Entra-only SQL.

## Teardown and data retention
Destroy deletes all stores; blob/container soft delete is 7 days.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Synapse PE has no private DNS zone (request `synapse_sql` zone key in foundation-network).
- ADX auto-stop does not apply to VNet-injected clusters (we use Private Link, so it applies).
- ADX double encryption on; CMK out of scope (checkov skips annotated).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py analytics                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/data-explorer/manage-cluster-choose-sku
- https://learn.microsoft.com/azure/data-explorer/auto-stop-clusters
- https://learn.microsoft.com/azure/search/service-create-private-endpoint
- https://learn.microsoft.com/azure/storage/blobs/data-lake-storage-introduction
- https://learn.microsoft.com/azure/synapse-analytics/security/synapse-workspace-managed-private-endpoints
