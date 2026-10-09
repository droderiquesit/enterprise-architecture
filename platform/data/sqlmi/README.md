# Azure SQL Managed Instance (platform-db-sqlmi)

- **Component id:** `platform-db-sqlmi` (catalog/components.yaml; catalog refs: `sql-managed-instance`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `disabled` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
General Purpose SQL Managed Instance (4 vCore, 32 GB, Entra-only) in the delegated `sqlmi` subnet with database
`adapter` for hello-dbadapter-sqlmi. **Disabled by default**: the first instance in a subnet takes ~4-6 hours to
create (timeouts set to 8 h) and the paid instance is expensive. Optional **free offer** (`pricingModel = Freemium`:
one GP instance per subscription, 4 or 8 vCores, 720 vCore-hours/month, 64 GB, 12 months).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-sqlmi` v1 — schema `catalog/contracts/platform-db-sqlmi.v1.schema.json` (output `contract`, no secrets).
When `enabled = false` the contract is `{enabled: false, server: null, databases: {}, dbm: null}`. Otherwise server (id, fqdn, pricing model, Entra admin), database `adapter` with grants, and `dbm` (`deployment_type = managed_instance`, Entra managed identity for obs-dbm).

## Settings (`components.platform-db-sqlmi` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `enabled` | `false` | |
| `entra_admin.{login,object_id,principal_type}` | required when enabled | |
| `free_offer` | `false` | AzAPI path (`Microsoft.Sql/managedInstances@2025-01-01`, `pricingModel = Freemium`) |
| `sku_name`, `vcores`, `storage_size_in_gb` | `GP_Gen5`, 4, 32 | free offer: 4/8 vCores, ≤64 GB |
| `license_type` | `LicenseIncluded` | |
| `pitr_retention_days` | 7 | |
| `stop_schedule_enabled`, `start_time`, `stop_time`, `schedule_timezone` | `true`, 07:00, 19:00, UTC | weekday start/stop schedule |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Disabled: 0. Enabled (paid, GP 4 vCore, license included): ~USD 700-800/month always-on; the weekday 07-19 schedule cuts compute to roughly 35% of hours (storage still billed). Free offer: 0 within the monthly vCore-hour credit.

## Private networking
VNet-injected into subnet `sqlmi` (delegation `Microsoft.Sql/managedInstances`). foundation-network must attach an
NSG and a route table to that subnet (service-aided subnet configuration adds the mandatory rules/routes). The
public data endpoint is disabled; clients connect on 1433 to the VNet-local endpoint.

## Authentication and data-plane access
Entra-only (`azuread_authentication_only_enabled`). Workload users via `platform/data/sql/scripts/grant-db-users.sql` (same procedure as platform-db-sql). DBM login for obs-dbm is created by observability (`CREATE LOGIN ... FROM EXTERNAL PROVIDER`, `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `CONNECT ANY DATABASE`).

## Teardown and data retention
Deleting the instance can itself take hours; databases are deleted with it. Free-offer instances are deleted by Azure 30 days after the 12-month offer ends unless upgraded.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- AzAPI gap: `azurerm_mssql_managed_instance` cannot set `pricingModel`; the free offer uses `azapi_resource` (Microsoft.Sql/managedInstances@2025-01-01).
- Free offer: no zone redundancy, failover groups or LTR; one per subscription.
- Subnet sizing/NSG/route table are foundation-network responsibilities.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py sqlmi                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/azure-sql/managed-instance/free-offer
- https://learn.microsoft.com/azure/azure-sql/managed-instance/vnet-subnet-determine-size
- https://learn.microsoft.com/azure/azure-sql/managed-instance/instance-stop-start-how-to
- https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
