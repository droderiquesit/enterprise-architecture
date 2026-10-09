# Azure HorizonDB (preview) (platform-db-horizondb)

- **Component id:** `platform-db-horizondb` (catalog/components.yaml; catalog refs: `horizondb`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `blocked` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Azure HorizonDB (preview; PostgreSQL 17-compatible) for hello-dbadapter-horizondb (`db adapter`). A public ARM API
exists — `Microsoft.HorizonDb/clusters` (2026-01-20-preview, 2026-05-01-preview) and `clusters/administrators`
(2026-05-01-preview) — so this root implements it with AzAPI behind `enabled = false` and a
`preview_access_confirmed` precondition. With defaults it creates **nothing** and its contract reports
`status = blocked`.

**Prerequisites to enable:** (1) subscription has preview access and `Microsoft.HorizonDb` is registered;
(2) region is one of the documented preview regions (Canada Central, Central US, East US, West US 2, West US 3,
Germany West Central, Sweden Central, Australia East, Korea Central — enforced by precondition);
(3) `entra_admin` set; (4) set `preview_access_confirmed = true`; (5) after creation read
`GET <cluster id>/privateLinkResources?api-version=2026-05-01-preview` and set `private_endpoint_group_id` to add the
private endpoint.

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-horizondb` v1 — schema `catalog/contracts/platform-db-horizondb.v1.schema.json` (output `contract`, no secrets).
`enabled`, `status` (`blocked`/`implemented`), `blocked_reason`, `api_version`, cluster (id, fqdn, port 5432, Entra-only), private endpoint, database `adapter` with grant, `dbm.supported = false`.

## Settings (`components.platform-db-horizondb` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `enabled` | `false` |
| `preview_access_confirmed` | `false` |
| `api_version` | `2026-05-01-preview` |
| `postgres_version`, `vcores`, `replica_count`, `zone_placement_policy` | `17`, 2, 1, `BestEffort` |
| `entra_admin` | required when enabled |
| `private_endpoint_group_id` | `null` |
| `admin_password_version` | 1 |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Disabled: 0. Enabled: preview pricing per vCore × replicas; verify before enabling.

## Private networking
HorizonDB preview supports public access with IP firewall (no rules by default ⇒ no public client can connect) and private endpoints; VNet injection is not available. The PE is created only once the group ID is known; no private DNS zone key exists yet in foundation-network.

## Authentication and data-plane access
`authConfig`: Entra ID enabled, password auth disabled; Entra admin via `clusters/administrators`. `administratorLogin`/password are still required at create: the password is ephemeral and sent through AzAPI `sensitive_body` (write-only, never in state). Workload role: reuse `platform/data/postgresql/scripts/grant-db-users.sql` pattern once preview Entra role functions are confirmed.

## Teardown and data retention
Destroy deletes the cluster; preview backup retention is a fixed 7 days.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- AzAPI gap: no azurerm resources. `schema_validation_enabled = false` because azapi 2.13 embeds only 2026-01-20-preview (no `authConfig`).
- Database `adapter` is created by the app/migration (no ARM database resource documented).
- Not a Datadog DBM deployment type.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py horizondb                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/horizondb/overview
- https://learn.microsoft.com/azure/horizondb/configure-maintain/quickstart-create-cluster
- https://learn.microsoft.com/azure/templates/microsoft.horizondb/2026-05-01-preview/clusters
- https://learn.microsoft.com/azure/horizondb/network/concepts-network-public
