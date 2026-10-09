# Azure DocumentDB (platform-db-documentdb)

- **Component id:** `platform-db-documentdb` (catalog/components.yaml; catalog refs: `documentdb`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Azure DocumentDB (formerly Azure Cosmos DB for MongoDB vCore, `azurerm_mongo_cluster`) on the smallest paid burstable tier **M10** (1 vCore, 2 GiB), 32 GiB, MongoDB-compatible version 8.0, high availability disabled (M10-M25 do not support in-region HA), Native + Microsoft Entra ID authentication; boundary `db adapter / collection records` for hello-dbadapter-documentdb (created by the app).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v2 | `identities[<name>].{principal_id, client_id, name}`, `secrets.{base_path, refs}` (Delinea DSV references) |

## Produced contract
`platform-db-documentdb` v1 — schema `catalog/contracts/platform-db-documentdb.v1.schema.json` (output `contract`, no secrets).
Cluster (id, host `<name>.global.mongocluster.cosmos.azure.com`, port 10260, auth methods, admin password secret ID), `auth_mode = entra-oidc` (driver `authMechanism=MONGODB-OIDC`), database/collection, `rbac[]`, `dbm.supported = false`.

## Settings (`components.platform-db-documentdb` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `compute_tier` | `M10` (Free rejected: no Entra) |
| `storage_size_in_gb` | 32 |
| `server_version` | `8.0` |
| `private_endpoint_enabled` | `true` |
| `admin_secret_name`, `secret_version` | `documentdb-admin-password`, 1 |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 35-50: M10 burstable compute + 32 GiB storage + private endpoint (~7.3). Free tier is cheaper but has no Entra ID, backup or Private Link guarantees for this lab.

## Private networking
`public_network_access = Disabled`; private endpoint group `MongoCluster`, zone key `mongocluster` (fallback alias `documentdb`).

## Authentication and data-plane access
Native auth must be enabled at creation (built-in admin `ehdocdbadmin`); its password comes from Delinea DSV `documentdb-admin-password` (pipeline input `TF_VAR_admin_password`; stored in state because `administrator_password` has no write-only argument). hello-dbadapter is registered as a Microsoft Entra principal (`azurerm_mongo_cluster_user`) — **least-privilege gap:** azurerm accepts only role `root` on `admin`, so the adapter receives root (lab-only; narrow via AzAPI/`mongoClusters/users` roles when available). The free tier is rejected because it does not support Entra ID.

## Teardown and data retention
Destroy deletes the cluster; backups of deleted clusters are kept 7 days by the service.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Entra role granularity (above).
- Native auth cannot be disabled until after provisioning (not automated).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py documentdb                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/documentdb/how-to-connect-role-based-access-control
- https://learn.microsoft.com/azure/documentdb/compute-storage
- https://learn.microsoft.com/azure/documentdb/limitations
