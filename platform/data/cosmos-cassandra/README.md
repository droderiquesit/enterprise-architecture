# Azure Cosmos DB for Apache Cassandra (platform-db-cosmos-cassandra)

- **Component id:** `platform-db-cosmos-cassandra` (catalog/components.yaml; catalog refs: `cosmos-cassandra`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Serverless Cassandra API account with keyspace `adapter` and ARM-managed table `records` (`id text` partition key, `payload text`, `created_at timestamp`) for hello-dbadapter-cosmos-cassandra.
Built with the shared module `platform/modules/data-cosmos-account` (account, capabilities, backup, private endpoint).

## Consumed contracts
`foundation-network` v1, `foundation-identity` v2 (fields: `variables.tf`).

## Produced contract
`platform-db-cosmos-cassandra` v1 — schema `catalog/contracts/platform-db-cosmos-cassandra.v1.schema.json` (output `contract`, no secrets).
Account (`local_auth_enabled = true`, port 10350), `auth_mode = key`, `key_secret_id`, keyspace/table, `dbm.supported = false`.

## Settings (`components.platform-db-cosmos-cassandra` in `environments/<env>/environment.yaml`)
| Key | Default | Notes |
|---|---|---|
| `capacity_mode` | `serverless` | single region, no free tier; `provisioned` uses autoscale |
| `free_tier_enabled` | `false` | provisioned only, one per subscription |
| `autoscale_max_throughput` | 1000 | provisioned only (autoscale floor = 10% of max) |
| `private_endpoint_enabled` | `true` | |
| `connection_string_secret_name`/`key_secret_name` | see variables.tf | DSV secret (`<prefix>/<env>/<name>`) holding the key (set out-of-band by an operator) |

## Cost at defaults (approx. USD/month)
Serverless: pay per RU consumed (~USD 0.25 per million RU) + storage (~0.25/GB) — typically < USD 5 for lab traffic — plus a private endpoint (~7.3). Provisioned autoscale 1000 RU/s max: ~USD 60/month per container minimum.

## Private networking
`public_network_access_enabled = false`, `network_acl_bypass_for_azure_services = false`, private endpoint group `Cassandra` in `private-endpoints`, zone key `cosmos_cassandra`. TLS 1.2 minimum.

## Authentication and data-plane access
**Key authentication (documented exception).** CQL drivers authenticate with account name + key. ARM exposes `cassandraRoleAssignments` (API 2026-03-15), but no documented driver-side Entra flow was found, so keys stay enabled. The primary key is stored out-of-band in Delinea DSV as `cosmos-cassandra-password` (`az cosmosdb keys list ... --query primaryMasterKey`); username = account name (contract `account.username`).

## Teardown and data retention
Destroy deletes the account. Continuous-backup accounts can be restored for the 7-day tier window after deletion (restorable deleted accounts). Backup policy: Periodic (1440 min interval, 168 h retention, Local).

## Known limitations / exceptions
- Continuous backup is not supported for the Cassandra API: periodic backup (24 h interval, 7 days retention, LRS).
- Revisit Entra once Microsoft documents client support for Cassandra RBAC.
