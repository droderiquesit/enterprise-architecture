# Azure Confidential Ledger (platform-db-ledger)

- **Component id:** `platform-db-ledger` (catalog/components.yaml; catalog refs: `confidential-ledger`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Private Azure Confidential Ledger. Collections `order-audit` (hello-functions audit) and `adapter` (hello-dbadapter-ledger) are created implicitly by the first data-plane write with that `collectionId`.

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v2 | `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-ledger` v1 — schema `catalog/contracts/platform-db-ledger.v1.schema.json` (output `contract`, no secrets).
Ledger (id, ledger endpoint, identity service endpoint, type), `auth_mode = entra-ledger-role`, collections, `rbac[]`, `private_endpoint.enabled = false`, `dbm.supported = false`.

## Settings (`components.platform-db-ledger` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `administrator_object_id` | **required** (ledger Administrator) |
| `ledger_type` | `Private` |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Per-instance daily charge (order of USD 3/day ≈ 90/month; verify current Confidential Ledger pricing) + transactions.

## Private networking
**Exception: no private endpoint.** The service exposes only its enclave-terminated TLS endpoint; no Private Link support (and no private DNS zone in foundation-network) was found. Record `networking.private_support = false` for this service in `catalog/services`.

## Authentication and data-plane access
Entra users via `azuread_based_service_principal`: Administrator (settings) and *Contributor* for hello-functions and hello-dbadapter. Clients must fetch the service identity certificate from the identity service endpoint.

## Teardown and data retention
Destroy deletes the ledger and its (synthetic) entries; ledger data is not recoverable.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Public endpoint only (above).
- Collections are not ARM-managed.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py ledger                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/confidential-ledger/overview
- https://learn.microsoft.com/azure/confidential-ledger/secure-confidential-ledger
- https://learn.microsoft.com/azure/confidential-ledger/authenticate-ledger-nodes
