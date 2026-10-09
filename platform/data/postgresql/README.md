# Azure Database for PostgreSQL Flexible Server (platform-db-postgresql)

- **Component id:** `platform-db-postgresql` (catalog/components.yaml; catalog refs: `postgresql-flexible`, `postgresql-elastic-cluster`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Flexible Server **PostgreSQL 18** (GA on Azure since 2025-09-25; also supported by Datadog DBM), Burstable
`B_Standard_B1ms`, 32 GB P4, 7-day backups, Entra-only auth (password auth disabled), databases `catalog`
(hello-catalog-api) and `adapter` (hello-dbadapter-postgresql). Optional **Elastic Cluster** (azurerm `cluster`
block: 2 nodes `GP_Standard_D2ds_v5`, default database `adapter`) for hello-dbadapter-postgresql-elastic with the
distributed table `adapter.records` (`scripts/elastic-distribute.sql`).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-postgresql` v1 — schema `catalog/contracts/platform-db-postgresql.v1.schema.json` (output `contract`, no secrets).
Server (fqdn, version, network mode, Entra admin, server parameters), per-database grants (identity name + Entra object ID), optional `elastic_cluster`, and `dbm` (`deployment_type = flexible_server`, Entra managed identity for obs-dbm, `required_parameters`).

## Settings (`components.platform-db-postgresql` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `entra_admin.{object_id,principal_name,principal_type}` | **required** | group recommended |
| `network_mode` | `vnet` | `vnet` = delegated subnet `postgres` + zone `postgres_vnet` (fallback `postgres`); `private-endpoint` = PE `postgresqlServer` |
| `version`, `sku_name`, `storage_mb`, `storage_tier` | `18`, `B_Standard_B1ms`, 32768, `P4` | |
| `backup_retention_days` | 7 | |
| `extra_extensions` | `[]` | appended to `azure.extensions` |
| `elastic_cluster.{enabled,node_count,sku_name,storage_mb,pe_group_id}` | `false`, 2, `GP_Standard_D2ds_v5`, 32768, `postgresqlServer` | Burstable SKUs rejected |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 17: B1ms (~13) + 32 GB storage (~4); backup within free allowance. Elastic cluster (disabled) ~USD 300+ for 2 GP nodes + PE.

## Private networking
Default VNet injection (no public endpoint exists). PE mode disables public access and adds a private endpoint. Elastic clusters do not support VNet injection; they always get a private endpoint and public access disabled.

## Authentication and data-plane access
Entra-only. After apply the pipeline, as a member of the Entra admin group, runs `scripts/grant-db-users.sql` per
`grants[]` entry: step `principal` (in `postgres`: `pgaadauth_create_principal_with_oid(<name>, <object id>, 'service', false, false)`)
and step `schema` (in the target db: CONNECT + schema ownership). **DBM:** obs-dbm needs a role too — the obs-dbm root,
running as an Entra admin member, creates it with `pgaadauth_create_principal('obs-dbm', false, false)` and grants
`pg_read_all_settings` + `pg_read_all_stats` (PG 16+), the `datadog` schema and `explain_statement` functions per
Datadog's managed-authentication guide. DBM server parameters set here: `azure.extensions=PG_STAT_STATEMENTS`,
`track_activity_query_size=4096` (static: restart), `pg_stat_statements.track=all`, `pg_stat_statements.max=10000`,
`pg_stat_statements.track_utility=off`, `track_io_timing=on`. `shared_preload_libraries` is left at the Flexible
Server default (which preloads pg_stat_statements); Datadog's Azure guide does not require changing it.

## Teardown and data retention
Destroy deletes the server; Azure keeps backups of a deleted server only for the documented deleted-server restore window.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- `track_activity_query_size` requires a server restart to take effect (not automated).
- Elastic-cluster Private Link group ID is assumed `postgresqlServer` (setting) — verify with `az network private-link-resource list` when enabling.
- Geo-redundant backup off (cost).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py postgresql                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-supported-versions
- https://learn.microsoft.com/azure/postgresql/elastic-clusters/concepts-elastic-clusters-limitations
- https://learn.microsoft.com/azure/postgresql/security/security-entra-configure
- https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/
- https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/
