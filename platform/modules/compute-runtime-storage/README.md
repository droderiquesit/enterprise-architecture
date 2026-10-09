# platform/modules/compute-runtime-storage

Shared **code** module (not a component) for storage accounts that compute *runtimes* need:
Functions host/deployment storage, Durable Functions runtime storage, Batch auto-storage and the
ML workspace default store. Owner: platform (compute). Ownership of each account stays with the
calling root (ADR-0001 §3 rule 1).

Defaults: `shared_access_key_enabled = false`, `default_to_oauth_authentication = true`,
TLS 1.2, no anonymous blob access, public network access **disabled**, 7-day blob/container soft
delete, SAS expiry policy (1 day, logged), optional private endpoints (`blob`, `queue`, `table`,
`file`, `dfs`) with DNS zone groups from the foundation-network contract, and RBAC grants
(account- or container-scoped). Diagnostic settings are intentionally absent (owned by
`obs-diagnostics`).

| Input | Notes |
|---|---|
| `name` | 3-24 lowercase alphanumerics (callers derive it from `foundation/modules/naming` `unique.storage`) |
| `public_network_access_enabled` | `true` only when the consumer cannot reach Private Link (e.g. Windows Consumption Functions) |
| `shared_access_key_enabled` | keep `false`; callers that must enable it document why |
| `containers`, `private_endpoints`, `private_dns_zone_ids`, `role_assignments` | see `main.tf` |

Outputs: `id`, `name`, `endpoints`, `containers` (name + URL), `private_endpoint_ids`.
