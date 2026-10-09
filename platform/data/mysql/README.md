# Azure Database for MySQL Flexible Server (platform-db-mysql)

- **Component id:** `platform-db-mysql` (catalog/components.yaml; catalog refs: `mysql-flexible`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Flexible Server **MySQL 8.4** (GA since 2025-09), `B_Standard_B1ms`, 20 GB, 7-day backups, Entra administrator, database `adapter` for hello-dbadapter-mysql, `performance_schema=ON` for Datadog DBM.

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-mysql` v1 — schema `catalog/contracts/platform-db-mysql.v1.schema.json` (output `contract`, no secrets).
Server (fqdn, version, Entra admin, server UAMI), database `adapter` with grant (identity name + client ID), and `dbm` (`auth_mode = native-password`: user `datadog`, `password_secret_id` = `foundation_identity.secret_ids["dbm-mysql-password"]` or the `dbm-mysql-password` convention).

## Settings (`components.platform-db-mysql` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `entra_admin.{login,object_id}` | **required** | |
| `server_identity_id` | `null` | existing UAMI; otherwise one is created here |
| `network_mode` | `vnet` | delegated subnet `mysql` + zone `mysql_vnet` (fallback `mysql`), or PE `mysqlServer` |
| `version`, `sku_name`, `storage_size_gb`, `backup_retention_days` | `8.4`, `B_Standard_B1ms`, 20, 7 | |
| `admin_password_version` | 1 | bump to rotate the write-only break-glass password |
| `dbm_password_secret_name` | `dbm-mysql-password` | fallback convention only |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 15: B1ms (~12) + 20 GB storage (~2.3).

## Private networking
VNet injection by default (no public endpoint); PE mode sets `public_network_access = Disabled` and creates a `mysqlServer` private endpoint.

## Authentication and data-plane access
Entra admin + native auth. Native auth stays enabled because Datadog DBM for MySQL documents only a native
`datadog` user (no Entra/managed identity), and the service requires an administrator login at creation. The
administrator password is **ephemeral and write-only** (`administrator_password_wo`): never in state or plans; reset
it with `az mysql flexible-server update --admin-password` for break-glass. Entra lookups use the server's UAMI,
which needs Microsoft Graph read permissions (`User.Read.All`, `GroupMember.Read.All`, `Application.Read.All`) or the
*Directory Readers* role granted by an Entra administrator out-of-band. Workload users: `scripts/grant-db-users.sql`
(`CREATE AADUSER '<name>' IDENTIFIED BY '<client id>'`), run as the Entra admin after apply. The DBM user is created
by obs-dbm with the password from Key Vault.

## Teardown and data retention
Destroy deletes the server and database.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Datadog: Query Activity and Wait Event collection are not supported on Flexible Server.
- Graph permissions for the server UAMI are an out-of-band Entra step.
- `performance_schema` is static (restart).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py mysql                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/mysql/concepts-version-policy
- https://learn.microsoft.com/azure/mysql/flexible-server/concepts-azure-ad-authentication
- https://docs.datadoghq.com/database_monitoring/setup_mysql/azure/
