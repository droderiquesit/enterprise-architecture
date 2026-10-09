# Azure SQL Database (platform-db-sql)

- **Component id:** `platform-db-sql` (catalog/components.yaml; catalog refs: `sql-database-provisioned`, `sql-database-serverless`, `sql-elastic-pool`, `sql-hyperscale`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Logical SQL server (Entra-only authentication, TLS 1.2, public network access disabled + private endpoint) with
the databases mapped in `catalog/architecture-matrix.yaml`:

| Database | Compute (default) | Owner identity | Also | Boundary |
|---|---|---|---|---|
| `orders` | provisioned DTU `S0` | hello-orders-api | — | schema `orders` |
| `fulfillment` | serverless `GP_S_Gen5_1`, min 0.5 vCore, auto-pause 60 min | hello-durable | hello-jobs | schema `fulfillment` |
| `adapter` | provisioned `Basic` | hello-dbadapter (dbadapter-sql) | — | schema `adapter` |
| `adapter_pool` (opt.) | Basic elastic pool (50 eDTU) | hello-dbadapter | — | `adapter_pool` |
| `adapter_hs` (opt.) | Hyperscale serverless `HS_S_Gen5_2` | hello-dbadapter | — | `adapter_hs` |

PITR 7 days, no LTR, locally redundant backup storage. Business tables are created by application migrations.

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-sql` v1 — schema `catalog/contracts/platform-db-sql.v1.schema.json` (output `contract`, no secrets).
Per database: `id`, `name`, `fqdn`, `port` 1433, `sku_name`, `compute_model`, `boundary`, `schemas`, `auth_mode`
(`entra-managed-identity`), `owner_identity_name`, `reader_writer_identity_names`, `grants[]` (identity name, client ID,
roles, schema) and `dbm_enabled`. Server: id, fqdn, Entra admin. `dbm` block for obs-dbm: engine `sqlserver`,
`deployment_type = sql_database`, `auth_mode = entra-managed-identity`, identity `obs-dbm` (client ID), host/port,
database list. **`fulfillment` is excluded from DBM** (`dbm_enabled = false`, `dbm.excluded_databases`): DBM's
continuous connections would prevent serverless auto-pause. `adapter_hs` is included only when its auto-pause is -1.

## Settings (`components.platform-db-sql` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `entra_admin.{login,object_id}` | **required** | Entra group; the pipeline apply identity must be a member |
| `private_endpoint_enabled` | `true` | PE `sqlServer` in subnet `private-endpoints`, zone key `sql` |
| `minimum_tls_version` | `1.2` | |
| `pitr_retention_days` | `7` | 1-35 |
| `backup_storage_redundancy` | `Local` | |
| `orders.{sku_name,max_size_gb}` | `S0`, 2 | |
| `fulfillment.{sku_name,min_capacity,auto_pause_delay_in_minutes,max_size_gb}` | `GP_S_Gen5_1`, 0.5, 60, 5 | must be `GP_S_*` |
| `adapter.{sku_name,max_size_gb}` | `Basic`, 2 | |
| `elastic_pool.{enabled,sku_name,tier,capacity,...}` | `false`, `BasicPool`, `Basic`, 50 | |
| `hyperscale.{enabled,sku_name,min_capacity,auto_pause_delay_in_minutes}` | `false`, `HS_S_Gen5_2`, 0.5, -1 | Hyperscale serverless auto-pause is a preview feature |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 35-50: S0 (~15) + Basic (~5) + serverless 1 vCore paused most of the day (~5-20 depending on activity; storage
billed while paused) + private endpoint (~7.3). Elastic pool Basic 50 eDTU ~+75; Hyperscale serverless 2 vCore
without auto-pause ~+250 (both disabled).

## Private networking
Public network access disabled. Private endpoint (`sqlServer`) in `private-endpoints`, DNS zone group with zone key `sql` when present. Connection policy `Default` (redirect inside Azure).

## Authentication and data-plane access
Entra-only (`azuread_authentication_only = true`): no SQL logins exist. Workload identities become contained users
via `scripts/grant-db-users.sql`, run by the pipeline **after apply** with an Entra token of a member of the admin
group, once per `contract.databases.<db>.grants[]` entry:

```bash
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
sqlcmd -S tcp:<fqdn>,1433 -d orders -G --access-token "$TOKEN" -b \
  -v IDENTITY_NAME=hello-orders-api CLIENT_ID=<client id> DB_ROLES=db_datareader,db_datawriter,db_ddladmin SCHEMA_NAME=orders \
  -i platform/data/sql/scripts/grant-db-users.sql
```

The script uses `CREATE USER ... WITH SID = <client id>, TYPE = E` (no Microsoft Graph lookup, so the server identity
needs no Directory Readers role). Owners get `db_ddladmin` for migrations. Diagnostic settings, Datadog resources and DBM users are owned by observability (`obs-diagnostics`, `obs-dbm`); this root only exposes the `dbm` block they need.

## Teardown and data retention
Deleting the server deletes all databases; PITR backups of dropped databases follow the service's retention for deleted databases (restorable-dropped list) until the server itself is deleted.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Auditing / vulnerability assessment are not configured here (diagnostic settings are observability-owned); checkov skips are annotated inline.
- Zone redundancy and geo backups are off (cost).
- Hyperscale serverless auto-pause is preview; default -1 (always on) when enabled.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py sql                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview
- https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases
- https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-only-authentication
- https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
- https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/
