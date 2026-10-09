# Azure Cosmos DB for Table (platform-db-cosmos-table)

- **Component id:** `platform-db-cosmos-table` (catalog/components.yaml; catalog refs: `cosmos-table`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Serverless Table API account with table `adapterrecords` for hello-dbadapter-cosmos-table.
Built with the shared module `platform/modules/data-cosmos-account` (account, capabilities, backup, private endpoint).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v2 | `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-cosmos-table` v1 — schema `catalog/contracts/platform-db-cosmos-table.v1.schema.json` (output `contract`, no secrets).
Account (`local_auth_enabled = false`), `auth_mode = entra-rbac`, table `adapterrecords`, `rbac[]`, `dbm.supported = false`.

## Settings (`components.platform-db-cosmos-table` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `capacity_mode` | `serverless` | single region, no free tier; `provisioned` uses autoscale |
| `free_tier_enabled` | `false` | provisioned only, one per subscription |
| `autoscale_max_throughput` | 1000 | provisioned only (autoscale floor = 10% of max) |
| `private_endpoint_enabled` | `true` | |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Serverless: pay per RU consumed (~USD 0.25 per million RU) + storage (~0.25/GB) — typically < USD 5 for lab traffic — plus a private endpoint (~7.3). Provisioned autoscale 1000 RU/s max: ~USD 60/month per container minimum.

## Private networking
`public_network_access_enabled = false`, `network_acl_bypass_for_azure_services = false`, private endpoint group `Table` in `private-endpoints`, zone key `cosmos_table`. TLS 1.2 minimum.

## Authentication and data-plane access
Local (key) authentication **disabled**. Data-plane RBAC: built-in *Cosmos DB Built-in Data Contributor* table role (`tableRoleDefinitions/00000000-0000-0000-0000-000000000002`) assigned to hello-dbadapter at account scope through **AzAPI** (`Microsoft.DocumentDB/databaseAccounts/tableRoleAssignments@2026-03-15`) — azurerm has no table role-assignment resource (provider gap).

## Teardown and data retention
Destroy deletes the account. Continuous-backup accounts can be restored for the 7-day tier window after deletion (restorable deleted accounts). Backup policy: Continuous (7-day tier).
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- AzAPI gap: `tableRoleAssignments` (API 2026-03-15, GA) has no azurerm resource.
- The role is scoped to the account (single table); narrow to the table scope once the scope path is verified.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py cosmos-table                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/cosmos-db/serverless
- https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints
- https://learn.microsoft.com/azure/cosmos-db/continuous-backup-restore-introduction
- https://learn.microsoft.com/azure/cosmos-db/table/how-to-connect-role-based-access-control
