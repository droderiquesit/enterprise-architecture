# Azure Cosmos DB for NoSQL (platform-db-cosmos-nosql)

- **Component id:** `platform-db-cosmos-nosql` (catalog/components.yaml; catalog refs: `cosmos-nosql`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Serverless NoSQL account with database `inventory` / container `items` (partition `/sku`, owner hello-inventory-api) and database `adapter` / container `records` (partition `/id`, owner hello-dbadapter-cosmos-nosql).
Built with the shared module `platform/modules/data-cosmos-account` (account, capabilities, backup, private endpoint).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-cosmos-nosql` v1 — schema `catalog/contracts/platform-db-cosmos-nosql.v1.schema.json` (output `contract`, no secrets).
Account (id, endpoint, host, port, capacity mode, local auth false), `auth_mode = entra-rbac`, databases/containers with partition keys and owners, `rbac[]`, `dbm.supported = false`.

## Settings (`components.platform-db-cosmos-nosql` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `capacity_mode` | `serverless` | single region, no free tier; `provisioned` uses autoscale |
| `free_tier_enabled` | `false` | provisioned only, one per subscription |
| `autoscale_max_throughput` | 1000 | provisioned only (autoscale floor = 10% of max) |
| `private_endpoint_enabled` | `true` | |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Serverless: pay per RU consumed (~USD 0.25 per million RU) + storage (~0.25/GB) — typically < USD 5 for lab traffic — plus a private endpoint (~7.3). Provisioned autoscale 1000 RU/s max: ~USD 60/month per container minimum.

## Private networking
`public_network_access_enabled = false`, `network_acl_bypass_for_azure_services = false`, private endpoint group `Sql` in `private-endpoints`, zone key `cosmos_sql`. TLS 1.2 minimum.

## Authentication and data-plane access
Local (key) authentication **disabled**. Data-plane RBAC: *Cosmos DB Built-in Data Contributor* (`sqlRoleDefinitions/00000000-0000-0000-0000-000000000002`) via `azurerm_cosmosdb_sql_role_assignment`, scoped to each owner's database (`/dbs/inventory`, `/dbs/adapter`).

## Teardown and data retention
Destroy deletes the account. Continuous-backup accounts can be restored for the 7-day tier window after deletion (restorable deleted accounts). Backup policy: Continuous (7-day tier).
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- The architecture matrix names the dbadapter boundary "container adapter"; this root implements database `adapter` / container `records` as specified for the data platform (flagged to the coordinator).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py cosmos-nosql                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/cosmos-db/serverless
- https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints
- https://learn.microsoft.com/azure/cosmos-db/continuous-backup-restore-introduction
- https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control
