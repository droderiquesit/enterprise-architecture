# Azure Managed Redis (platform-db-redis)

- **Component id:** `platform-db-redis` (catalog/components.yaml; catalog refs: `managed-redis`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Azure Managed Redis (`azurerm_managed_redis`, Microsoft.Cache/redisEnterprise) `Balanced_B0`, HA off, TLS (`Encrypted`), access keys disabled, `AllKeysLRU` eviction (cache semantics), **no persistence**, `EnterpriseCluster` policy (single endpoint for non-cluster-aware clients). Boundaries are key prefixes: `catalog:` (hello-catalog-api cache-aside) and `adapter:` (hello-dbadapter-redis). `azurerm_redis_cache` (Azure Cache for Redis, retiring) is deliberately not used.

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v2 | `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-redis` v1 — schema `catalog/contracts/platform-db-redis.v1.schema.json` (output `contract`, no secrets).
Cache (id, hostname, port 10000, TLS, eviction, persistence `none`), `auth_mode = entra-access-policy`, key-prefix boundaries, `rbac[]`, `dbm.supported = false`.

## Settings (`components.platform-db-redis` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `sku_name` | `Balanced_B0` |
| `high_availability_enabled` | `false` |
| `eviction_policy` | `AllKeysLRU` |
| `clustering_policy` | `EnterpriseCluster` |
| `private_endpoint_enabled` | `true` |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 15-25: Balanced_B0 (non-HA) plus private endpoint (~7.3).

## Private networking
`public_network_access = Disabled`; private endpoint group `redisEnterprise`, zone key `redis` (privatelink.redis.azure.net).

## Authentication and data-plane access
Access keys disabled; Entra ID via `azurerm_managed_redis_access_policy_assignment` (default data-owner access policy) for hello-catalog-api and hello-dbadapter. Prefix isolation is by convention (the default policy is not prefix-scoped).

## Teardown and data retention
Destroy deletes the cache; no data is persisted (by design).
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Key-prefix boundaries are not enforced by ACL (custom access policies are not modelled by azurerm).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py redis                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/redis/overview
- https://learn.microsoft.com/azure/redis/entra-for-authentication
- https://learn.microsoft.com/azure/redis/private-link
