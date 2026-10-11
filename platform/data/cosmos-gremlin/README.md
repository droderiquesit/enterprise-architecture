# Azure Cosmos DB for Apache Gremlin (platform-db-cosmos-gremlin)

- **Component id:** `platform-db-cosmos-gremlin` (catalog/components.yaml; catalog refs: `cosmos-gremlin`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Serverless Gremlin account with database `adapter` / graph `records` (partition key `/pk`) for hello-dbadapter-cosmos-gremlin.
Built with the shared module `platform/modules/data-cosmos-account` (account, capabilities, backup, private endpoint).

## Consumed contracts
`foundation-network` v1, `foundation-identity` v2 (fields: `variables.tf`).

## Produced contract
`platform-db-cosmos-gremlin` v1 — schema `catalog/contracts/platform-db-cosmos-gremlin.v1.schema.json` (output `contract`, no secrets).
Account (`local_auth_enabled = true`), `auth_mode = key`, `key_secret_id`, database/graph, `dbm.supported = false`.

## Settings (`components.platform-db-cosmos-gremlin` in `environments/<env>/environment.yaml`)
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
`public_network_access_enabled = false`, `network_acl_bypass_for_azure_services = false`, private endpoint group `Gremlin` in `private-endpoints`, zone key `cosmos_gremlin`. TLS 1.2 minimum.

## Authentication and data-plane access
**Key authentication (documented exception).** The Gremlin wire protocol authenticates with the account key (Service Connector documents that Cosmos DB does not natively accept managed-identity tokens for Gremlin). The primary key is stored out-of-band as Delinea DSV secret `cosmos-gremlin-key`; Gremlin username is `/dbs/adapter/colls/records`.

## Teardown and data retention
Destroy deletes the account. Continuous-backup accounts can be restored for the 7-day tier window after deletion (restorable deleted accounts). Backup policy: Continuous (7-day tier).

## Known limitations / exceptions
- Key-based auth (above).
