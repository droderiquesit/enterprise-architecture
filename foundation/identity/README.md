# foundation-identity

- **Owner:** platform-engineering · **Component id:** `foundation-identity` · **State key:** `<env>/foundation-identity.tfstate`
- **Purpose:** every workload user-assigned managed identity, the per-identity list of **Delinea DSV** secret names it may
  read, and the DSV references (`dsv://<prefix>/<env>/<name>#value`) of every lab secret. No Azure Key Vault (ADR-0001
  section 14: all keys and secrets live in Delinea DSV; workloads read DSV directly with these identities). Secret
  **values** are never managed by Terraform.
- **Consumes:** nothing (the global `secrets` section of `environments/<env>/environment.yaml`: DSV tenant, tld, auth provider).
- **Produces:** `foundation-identity` **v2** ([schema](../../catalog/contracts/foundation-identity.v2.schema.json)); v1 (Key
  Vault ids, `secret_ids`) was removed. Consumers: `foundation-secrets` (DSV users/permissions), platform roots
  (identities; data roots also `secrets.base_path`/`refs`), observability and application roots.
- **Status:** implemented (validate + mock tests + `tests/test_no_secret_values.py`). Not deployed.

## Contract v2

```json
{ "resource_group_name": "...", "tenant_id": "<entra tenant>",
  "identities": { "<key>": { "id", "principal_id", "client_id", "name", "secrets": ["<secret-name>", ...] } },
  "secrets": { "provider": "delinea-dsv", "tenant": "<tenant>", "tld": "com",
               "base_url": "https://<tenant>.secretsvaultcloud.<tld>/v1", "base_path": "<prefix>/<env>",
               "auth_provider": "<DSV azure auth provider>",
               "refs": { "<secret-name>": "dsv://<prefix>/<env>/<secret-name>#value" } } }
```

References are not secrets (ADR-0001 section 14) and may appear in contracts, state, app settings and Helm values.

## Workload identities (contract `identities.<key>`)

| Key | DSV secrets it reads (foundation-secrets grants `read` on exactly these paths) |
|---|---|
| hello-bff, hello-orders-api, hello-catalog-api, hello-functions | `fault-token`, `datadog-api-key` (dsv-fetch for Datadog serverless-init on Container Apps; the Fluent Bit sidecar only with `log_pipeline = fluent_bit_direct`) |
| hello-inventory-api, hello-dbadapter | `fault-token`, `datadog-api-key` (Container Apps serverless-init as above; on VMs / VMSS the policy-enrolled Agent uses `obs-host-agent`); hello-dbadapter also the adapter secrets |
| hello-durable, hello-traffic | `fault-token` |
| hello-worker | — (runs on AKS / VM / VMSS: the node Agent uses `obs-collector`, policy-enrolled host Agents use `obs-host-agent`; observability 4.0.0 installs no Fluent Bit on hosts) |
| hello-partner-sim | `fault-token`, `datadog-api-key` (the `dsv-fetch` init container of the ACI Datadog Agent sidecar reads it with this identity) |
| hello-jobs | `datadog-api-key` (Batch job preparation task installs Fluent Bit with the pool identity, ADR-0001 §13) |
| obs-collector (Fluent Bit aggregator / OTel gateway) | `datadog-api-key`, `fluentbit-shared-key` (aggregator forward input), `eventhub-fluentbit-listen` (kafka input) |
| obs-dbm (Datadog Agent DBM) | `datadog-api-key`, `dbm-<engine>-password` |
| obs-host-agent (Datadog Agent on VMs / VMSS, attached by the obs-hosts Azure Policy to every host tagged `datadog:enabled`) | `datadog-api-key` only (the Agent's dsv-fetch secret backend; any process on an enrolled host can use the identity - accepted risk, ingest-only key) |
| deploy-agent (pipelines) | pipeline secrets `datadog-api-key`, `datadog-app-key`, `datadog-client-token`, `fault-token` and the platform apply inputs (`sqlvm-admin-password`, `sqlvm-dbadapter-password`, `documentdb-admin-password`, `cassandra-mi-admin-password`, `mysql-admin-password`, `appgw-tls-pfx`, `aro-pull-secret`); also publishes generated values (create/update on `eventhub-fluentbit-listen`) and lists paths for `check.py` |
| aks-control-plane, aks-kubelet, hello-logicapps, hello-frontend | — |

Plus `settings.extra_identities`. Platform roots grant everything else (AcrPull, SQL/Cosmos data roles, Service Bus, etc.)
because they own those resources (ADR §3). Names: `<prefix>-id-<key>-<env>-<region>`.

## Secrets (catalogue `secrets.yaml`, contract `secrets.refs`)

[`secrets.yaml`](secrets.yaml) is the catalogue of every lab secret: **names and metadata only** (source `operator` |
`generated`, publisher, `required_by` components). `tools/secrets/check.py` uses `required_by` to verify that an
environment's required paths exist (never reading values). Path `/<prefix>/<env>/<name>`, element `value`.

| Name | Readers | Source |
|---|---|---|
| `datadog-api-key` | agents, Fluent Bit, OTel gateway, deploy-agent | operator (Datadog org settings) |
| `datadog-app-key` | deploy-agent only (Datadog Terraform provider) | operator |
| `datadog-client-token` | deploy-agent (injected into the frontend build) | operator (Datadog RUM app) |
| `fault-token` | HTTP services + traffic generator, deploy-agent (smoke) | operator (generate) |
| `fluentbit-shared-key` | obs-collector | operator (generate) |
| `eventhub-fluentbit-listen` | obs-collector | **generated** - `obs-telemetry-transport` output `generated_secrets`, written by `tools/secrets/publish.py` after apply |
| adapter secrets (`sqlvm-dbadapter-password`, `cassandra-mi-dbadapter-password`, `cosmos-*`) | hello-dbadapter | operator |
| `dbm-<engine>-password` (`settings.dbm_sql_auth_engines`) | obs-dbm | operator |
| platform apply inputs (`sqlvm-admin-password`, `documentdb-admin-password`, `cassandra-mi-admin-password`, `mysql-admin-password`, `appgw-tls-pfx`, `aro-pull-secret`) | deploy-agent | operator |

DBM authentication per engine (Datadog [managed authentication guide](https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/), checked 2026-10-09):
**PostgreSQL Flexible** → managed identity (`azure.managed_authentication`, Agent ≥ 7.48) → no password;
**Azure SQL DB / SQL MI** → managed identity (`managed_identity.client_id`, ODBC driver ≥ 17) → no password;
**MySQL Flexible** and **SQL Server on VM** → SQL auth passwords above (`settings.dbm_sql_auth_engines`).

Set and rotate values with the DSV CLI (`dsv secret create|update --path <prefix>/<env>/<name> --data @file.json`) -
[docs/runbooks/secret-rotation.md](../../docs/runbooks/secret-rotation.md). The former `scripts/set-secrets.sh` (Key Vault)
was removed.


## Settings (`components.foundation-identity`)

| Key | Default |
|---|---|
| `extra_identities` | `{}` (key => purpose) |
| `extra_identity_secrets` | `{}` (identity key => extra catalogue secret names) |
| `dbm_sql_auth_engines` | `["mysql", "sqlvm"]` |
| `packages_container_id` / `package_reader_identities` | `null` / adapter, worker, inventory, durable, functions, jobs |

Global `secrets` (environment.yaml, rendered as `var.secrets`): `provider = delinea-dsv`, `tenant`, `tld` (`com`, `eu`,
`com.au`, `ca`), `auth_provider`, optional `base_url`.

## Cost at defaults

≈ USD 0/month in Azure: managed identities and role assignments are free (the former Key Vault + private endpoint,
≈ USD 8/month, is gone). Delinea DSV is a separate subscription (catalog entry `delinea-dsv`).

## Teardown and data retention

Destroy *after* platform/application roots that reference the identities; role assignments and federated credentials
created by other roots on these identities must be destroyed first (their roots own them). Destroying an identity
breaks its DSV user mapping (externalId = the identity resource id); a re-created identity has a new principal and
the same resource id, so `foundation-secrets` keeps working. Secret values live only in DSV and are not touched.

## Private networking

No data-plane endpoint in Azure. Readers reach DSV over HTTPS (`<tenant>.secretsvaultcloud.<tld>`); the Azure Firewall
default allow-list (`foundation-edge`) includes `*.secretsvaultcloud.*`.

## Known limitations

- AKS pods authenticate to DSV with workload identity: whether DSV accepts workload-identity-federated tokens (it maps
  users by the `xms_mirid` claim) is **not verified**; fallback documented in `docs/known-limitations.md`.
- `hello-frontend` gets no secret access; the RUM client token is injected by the deployment pipeline.

## Validation

```bash
tools/validate/terraform.sh foundation/identity   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
python3 -m pytest foundation/identity/tests -q                 # static guards (no secret values / Key Vault)
```

## References

- Delinea DSV Azure authentication: https://docs.delinea.com/dsv/current/usage/auth-general/authazure
- Delinea DSV policies: https://docs.delinea.com/online-help/devops-secrets-vault/tutorials/policy.htm
- User-assigned managed identities: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview
