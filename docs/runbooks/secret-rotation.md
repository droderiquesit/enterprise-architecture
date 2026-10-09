# Runbook: secret rotation (Delinea DevOps Secrets Vault)

All lab keys and secrets live in **Delinea DSV** ([ADR-0001 section 14](../architecture/ADR-0001-design-contract.md#14-secret-management-delinea-devops-secrets-vault-dsv)).
Azure Key Vault is not used for secrets. Each secret is the DSV secret `/<prefix>/<env>/<name>` with element `value`
(e.g. `eh/dev/datadog-api-key`); consumers hold only references `dsv://<prefix>/<env>/<name>#value` and read the value
directly from DSV with their own managed identity. The catalogue of names, sources and consumers is
[`foundation/identity/secrets.yaml`](../../foundation/identity/secrets.yaml). None of these procedures has been executed
against a live DSV tenant.

Tooling (operator workstation with the `dsv` CLI signed in to the tenant, or the self-hosted deploy pool):

```bash
umask 077
# create / update a value (never on the command line: the JSON goes through a 0600 file in memory)
printf '{"value":"%s"}' "$(openssl rand -base64 36)" > /dev/shm/v.json
dsv secret update --path eh/dev/fault-token --data @/dev/shm/v.json   # `create` for a new path
rm -f /dev/shm/v.json
dsv secret describe --path eh/dev/fault-token                          # metadata + version, no value
dsv secret rollback --path eh/dev/fault-token --version <n>            # DSV keeps secret versions
python3 tools/secrets/check.py --env dev                               # required paths present? (names only)
```

Values Azure generates (today: `eventhub-fluentbit-listen`) are written by `tools/secrets/publish.py` in the publisher
component's apply job; do not edit them by hand.

## Pick-up time per consumer

| Consumer mechanism | When the new value is used |
|---|---|
| Application code (`hello_common` / `Hello.Common` resolve `dsv://` env vars at start-up, cache `DSV_CACHE_TTL_SECONDS`, default 900 s) | next refresh, or restart the revision / pod / app (`az containerapp revision restart`, `kubectl rollout restart`, `az webapp restart`) |
| Containers without our code (Fluent Bit, OTel gateway): `dsv-fetch init` init container writes in-memory files | only on container restart (new ACA revision / pod restart / ACI restart) |
| Datadog Agent `secret_backend_command` (`dsv-fetch agent-backend`, `ENC[dsv://...]`) on VM/VMSS/AKS | Agent restart (or the Agent's secret refresh interval when configured) |
| Pipelines (`tools/secrets/fetch.py` per step) | next run |
| Terraform inputs that land in state (SQL VM, DocumentDB, Cassandra MI, App Gateway PFX, ARO pull secret) | next apply of the owning root (the plan shows the sensitive change) |

## Per secret

| Secret | Source | Rotation steps |
|---|---|---|
| `datadog-api-key` | Datadog org settings | create a new key in Datadog -> `dsv secret update` -> restart agents/collectors (obs-kubernetes pods, VM agents, Fluent Bit sidecars, aggregator, OTel gateway, ACI partner-sim) -> confirm the telemetry canary and `pipeline.*` monitors are green -> revoke the old key in Datadog |
| `datadog-app-key` | Datadog org settings | pipeline-only (Datadog provider, telemetry verifier, DORA events): update, run a `drift`-mode pipeline to confirm, revoke the old key |
| `datadog-client-token` | Datadog RUM application | browser-facing by design; update, redeploy the frontend (`deploy-frontend` re-renders `config.json`) |
| `fault-token` | generated | `dsv secret update` with a random value, then restart consumers (all HTTP services + hello-traffic) |
| `fluentbit-shared-key` | generated | update, then restart aggregator and forwarders together (a mismatch drops forwarded logs) |
| `eventhub-fluentbit-listen` | **generated** by `obs-telemetry-transport` | `az eventhubs namespace authorization-rule keys renew` for the listen rule, re-run `obs-telemetry-transport` (its apply job runs `publish.py`, which updates the DSV value), restart the aggregator revision |
| `dbm-mysql-password` | generated | update in DSV, `ALTER USER 'datadog'@'%' IDENTIFIED BY '<new>'` (grant script `platform/data/mysql/scripts/grant-db-users.sql`), restart the DBM agent |
| `dbm-sqlvm-password` | generated | update in DSV, `ALTER LOGIN datadog WITH PASSWORD = '<new>'` on the SQL VM, restart the agent |
| `sqlvm-dbadapter-password` | generated (platform-db-sqlvm input) | update in DSV, re-run `platform-db-sqlvm` (the run command re-applies the login password), restart the adapter |
| `sqlvm-admin-password` | generated (platform-db-sqlvm input) | reset on the VM first (`az vm user update --username ehsqladmin --password ...` via the pipeline identity), update DSV, re-run `platform-db-sqlvm` so state matches |
| `documentdb-admin-password`, `cassandra-mi-admin-password` | generated (platform input) | update DSV, re-run the platform root (the value is an in-place update of the cluster) |
| `mysql-admin-password` (optional) | generated | update DSV, bump `components.platform-db-mysql.admin_password_version`, apply (write-only, never in state). Without the DSV secret the root uses an ephemeral random value |
| HorizonDB admin password | ephemeral, write-only | bump the root's `admin_password_version`, apply (never in state) |
| Cosmos Mongo / Cassandra / Gremlin keys (`cosmos-mongo-connection-string`, `cosmos-cassandra-password`, `cosmos-gremlin-key`) | Azure keys copied by an operator | `az cosmosdb keys regenerate --key-kind secondary`, store the secondary in DSV, restart adapters, then regenerate primary |
| `appgw-tls-pfx` (`value` = base64 PFX, `password`) | your CA | update both elements, re-run `foundation-edge` |
| `aro-pull-secret` | Red Hat console | update, re-run `platform-aro` |
| `datadog-azure-client-secret` (FED / sovereign only) | `az ad app credential reset` (bootstrap/README.md) | reset, `dsv secret update`, re-run `obs-azure-integration` |
| Federated credentials (pipeline, Datadog Secretless) | no secret | issuer/subject changes only: update `components.bootstrap.federated_credentials`, re-run bootstrap |

## Access changes

Who may read what is not edited by hand: `foundation-secrets` renders one DSV user per managed identity and one
`read` permission per user on exactly the identity's paths (`foundation/identity` `secrets` lists); the pipeline's
`dsv_apply.py` converges it (plan shows the diff). To grant an identity another secret, add the name to its list
(or `components.foundation-identity.extra_identity_secrets`) and deploy foundation-identity + foundation-secrets.

## Break-glass

- DSV unreachable: running workloads keep their cached / file values until restart; do not restart them. Pipelines
  that need secrets fail fast in `fetch.py` (names only). There is no secondary copy by design (no other vault).
- Compromised value: update it in DSV (new version), restart consumers, then revoke at the source (Datadog key, Azure key).
- Compromised identity mapping: remove the user's permission in DSV (`dsv policy edit`) - the next `foundation-secrets`
  plan shows it as a pending change until the identity list is fixed.

## Secrets that land in Terraform state (accepted, documented)

State and saved plans are in the private, Entra-only, versioned state account; treat them as secret. Values from DSV
are passed to arguments **without a write-only form** in azurerm 5.9 and are therefore stored there: SQL VM admin +
adapter passwords, DocumentDB admin, Cassandra MI admin, App Gateway PFX + password, ARO pull secret, plus Azure-generated
keys of resources the lab creates (Event Hubs authorization rule keys in `obs-telemetry-transport`). MySQL/HorizonDB admin
passwords are write-only/ephemeral and never stored. List: [known limitations](../known-limitations.md#secrets-in-terraform-state).
