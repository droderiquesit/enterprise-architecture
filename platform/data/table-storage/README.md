# Azure Table Storage (platform-db-table-storage)

- **Component id:** `platform-db-table-storage` (catalog/components.yaml; catalog refs: `table-storage`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
StorageV2 account (LRS, TLS 1.2, shared key disabled, OAuth default, public network access disabled) with tables `notifications` (hello-worker) and `adapterrecords` (hello-dbadapter-table-storage).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v2 | `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-table-storage` v1 — schema `catalog/contracts/platform-db-table-storage.v1.schema.json` (output `contract`, no secrets).
Account (id, table endpoint), `auth_mode = entra-rbac`, tables with owners, `rbac[]` (Storage Table Data Contributor per table), `dbm.supported = false`.

## Settings (`components.platform-db-table-storage` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `replication_type` | `LRS` |
| `private_endpoint_enabled` | `true` |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
< USD 1 for storage/transactions + private endpoint (~7.3).

## Private networking
Public network access disabled, network rules default Deny with no bypass; private endpoint `table`, zone key `table`.

## Authentication and data-plane access
Shared key disabled. *Storage Table Data Contributor* assigned per table (table-scoped ARM ID) to the owner identity. Tables are created through ARM (`storage_account_id`), so Terraform needs no data-plane access.

## Teardown and data retention
Destroy deletes the account and tables (no soft delete for tables).
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Storage logging is a diagnostic setting owned by obs-diagnostics (checkov skips annotated).

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py table-storage                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/storage/tables/authorize-access-azure-active-directory
- https://learn.microsoft.com/azure/storage/common/shared-key-authorization-prevent
