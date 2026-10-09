# foundation-identity

- **Owner:** platform-engineering · **Component id:** `foundation-identity` · **State key:** `<env>/foundation-identity.tfstate`
- **Purpose:** the lab Key Vault (RBAC, private endpoint only), every workload user-assigned managed identity, and the
  Key Vault data-plane RBAC that lets those identities read the secrets they need. Secret **values** are never managed by Terraform.
- **Consumes:** `foundation-network` (`subnets["private-endpoints"].id`, `private_dns_zones["vault"].id`).
- **Produces:** `foundation-identity` v1 ([schema](../../catalog/contracts/foundation-identity.v1.schema.json)).
- **Status:** implemented (validate + mock tests + `tests/test_no_secret_values.py`). Not deployed.

## Key Vault

| Property | Value |
|---|---|
| Name | `module.naming.unique.key_vault` (e.g. `eh-kv-identi-dev-<5 hex>`) |
| Authorization | Azure RBAC (`rbac_authorization_enabled = true`), no access policies |
| Network | `public_network_access_enabled = false`, ACL default `Deny`, bypass `AzureServices`; private endpoint (`vault`) in `private-endpoints` with zone `privatelink.vaultcore.azure.net` via `foundation/modules/private-endpoint` |
| Soft delete / purge protection | 7 days / **on** by default |

**Teardown implication of purge protection:** a deleted vault stays soft-deleted for `soft_delete_retention_days` (7) and
*cannot be purged*; its name (deterministic: prefix+env+subscription hash) cannot be reused until then, so a destroy +
re-create of the same environment within 7 days fails. Either wait, use a different `name_prefix`/environment, or set
`purge_protection_enabled = false` for throwaway labs **before** the first apply (it can never be turned off afterwards).

## Workload identities (contract `identities.<key>`)

| Key | Runtime secrets (Key Vault Secrets User) |
|---|---|
| hello-bff, hello-orders-api, hello-catalog-api, hello-functions | `fault-token`, `datadog-api-key` (Fluent Bit sidecar on Container Apps, `sidecar_mode = datadog`) |
| hello-inventory-api, hello-dbadapter | `fault-token`, `datadog-api-key` (ACA sidecar and the VM/VMSS Fluent Bit installer of obs-hosts, which reads the key with the host identity); hello-dbadapter also the adapter secrets |
| hello-durable, hello-partner-sim, hello-traffic | `fault-token` (partner-sim's ACI sidecar key is resolved by the pipeline at plan time) |
| hello-worker | `datadog-api-key` (VM/VMSS Fluent Bit installer, obs-hosts) |
| hello-jobs | `datadog-api-key` (Batch job preparation task installs Fluent Bit with the pool identity, ADR-0001 §13) |
| hello-frontend | — |
| obs-collector (Fluent Bit aggregator / OTel gateway) | `datadog-api-key`, `fluentbit-shared-key` (aggregator forward input) |
| obs-dbm (Datadog Agent DBM) | `datadog-api-key`, `dbm-<engine>-password` |
| aks-control-plane, aks-kubelet, deploy-agent | — |

Plus `settings.extra_identities`. Platform roots grant everything else (AcrPull, SQL/Cosmos data roles, Service Bus, etc.)
because they own those resources (ADR §3). Names: `<prefix>-id-<key>-<env>-<region>`.

**RBAC scope.** Default: *Key Vault Secrets User at vault scope* — a secret-scoped assignment needs the secret to exist,
and secrets are created after this root. Once every secret exists, set `secret_scoped_assignments = true` to switch to one
assignment per identity × secret (true least privilege; the vault-scoped ones are replaced in the same apply).

## Secrets (contract `secret_ids`, versionless `<vault_uri>secrets/<name>`)

| Name | Used by | Notes |
|---|---|---|
| `datadog-api-key` | agents, Fluent Bit, OTel gateway; pipeline | |
| `datadog-app-key` | pipeline only (Datadog Terraform provider) | grant with `pipeline_reader_principal_ids` |
| `fault-token` | HTTP services + traffic generator | `X-Fault-Token` for `POST /admin/faults` |
| `datadog-client-token` | deploy pipeline injects into the frontend build | browser-safe RUM token, still stored centrally |
| `fluentbit-shared-key` | obs-collector (aggregator forward input); app identities only when `sidecar_mode = forward` | Fluent Bit forward protocol shared key; `set-secrets.sh <vault> generate fluentbit-shared-key` |
| `dbm-mysql-password` | obs-dbm | MySQL Flexible: the Datadog DBM check has no Entra managed-identity auth → SQL auth |
| `dbm-sqlvm-password` | obs-dbm | SQL Server on VM: no Entra-joined SQL by default → SQL login |

DBM authentication per engine (Datadog [managed authentication guide](https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/), checked 2026-10-09):
**PostgreSQL Flexible** → managed identity (`azure.managed_authentication`, Agent ≥ 7.48) → no password;
**Azure SQL DB / SQL MI** → managed identity (`managed_identity.client_id`, ODBC driver ≥ 17) → no password;
**MySQL Flexible** and **SQL Server on VM** → SQL auth passwords above (`settings.dbm_sql_auth_engines`).

Set and rotate values with [`scripts/set-secrets.sh`](scripts/set-secrets.sh) from a host on the VNet (the vault has no
public access): `set-secrets.sh <vault> set datadog-api-key`, `... generate fault-token`, `... generate fluentbit-shared-key`, `... rotate dbm-mysql-password`
(rotation disables old versions; consumers use versionless IDs and pick up the new version on their refresh cycle).
The operator needs Key Vault Secrets Officer (`secret_officer_principal_ids`).

## Settings (`components.foundation-identity`)

| Key | Default |
|---|---|
| `key_vault_sku` | `standard` |
| `purge_protection_enabled` / `soft_delete_retention_days` | `true` / `7` |
| `public_network_access_enabled` / `allowed_ip_ranges` | `false` / `[]` (break-glass only) |
| `extra_identities` | `{}` (key => purpose) |
| `dbm_sql_auth_engines` | `["mysql", "sqlvm"]` |
| `secret_scoped_assignments` | `false` |
| `secret_officer_principal_ids` / `pipeline_reader_principal_ids` | `[]` / `[]` |

## Cost at defaults

≈ USD 8/month: private endpoint ≈ 7.3 + Key Vault operations (0.03 per 10k). Managed identities and RBAC are free.

## Teardown and data retention

Secret values live only in Key Vault; destroying the vault soft-deletes it (7 days, not purgeable with purge protection).
Destroy *after* platform/application roots that reference identities. Identities are deleted immediately; role assignments
and federated credentials created by other roots on these identities must be destroyed first (their roots own them).

## Private networking

Vault reachable only through the private endpoint; Terraform management-plane operations (create vault, role assignments)
do not need data-plane access, so Microsoft-hosted agents can apply this root. Setting secret values needs VNet access.

## Known limitations

- Vault-scoped Secrets User by default (see RBAC scope above).
- `hello-frontend` gets no secret access; the RUM client token is injected by the deployment pipeline.

## References

- Key Vault RBAC: https://learn.microsoft.com/azure/key-vault/general/rbac-guide
- Soft delete / purge protection: https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview
- Private endpoint DNS: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
