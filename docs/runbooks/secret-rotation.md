# Runbook: secret rotation

Secrets live in the foundation Key Vault (`foundation-identity`: RBAC, public access disabled, purge protection).
Terraform never manages secret **values** except where noted under "secrets in state". Consumers reference
**versionless** secret IDs (contracts `secret_ids`), so a new version is picked up without a Terraform change.
None of these procedures has been executed against a live vault.

Tool: [`foundation/identity/scripts/set-secrets.sh`](../../foundation/identity/scripts/set-secrets.sh) - run it from a
host that reaches the vault's private endpoint (deploy agent, Bastion-connected VM, peered network) with
*Key Vault Secrets Officer* (`components.foundation-identity.secret_officer_principal_ids`).

```bash
set-secrets.sh <vault> list                         # names + updated time only
set-secrets.sh <vault> set <name> [--from-env VAR]  # new version
set-secrets.sh <vault> generate fault-token         # random 48-byte token
set-secrets.sh <vault> rotate <name>                # new version, then disable older versions
```

Rollback of a rotation: `az keyvault secret set-attributes --vault-name <vault> --name <name> --version <old> --enabled true`
(old versions are disabled, not deleted).

## Pick-up time per consumer

| Consumer mechanism | When the new version is used |
|---|---|
| Container Apps `secret { key_vault_secret_id, identity }` (BFF, orders, catalog, adapters, jobs, transport) | ACA secret refresh (~30 min) - restart a revision to force |
| App Service / Functions `@Microsoft.KeyVault(SecretUri=...)` | up to ~24 h or on restart (`az webapp restart`, `az functionapp restart`) |
| AKS Secrets Store CSI driver | rotation poll (platform-aks enables rotation, 2 min); env vars from synced Secrets need a pod restart (`kubectl rollout restart deployment/<svc> -n hello`) |
| VM / VMSS (fetched on the host via IMDS) | next install/run command - re-run `deploy-vm-workloads` (bump `package_force`) |
| ACI partner-sim (read at **plan** time into `secure_environment_variables`) | only after re-applying `deploy-partner-sim` (container group recreated, brief outage) |
| Pipeline (variable group linked to Key Vault) | next run |

## Per secret

| Secret | Source | Rotation steps |
|---|---|---|
| `datadog-api-key` | Datadog org settings | create a new key in Datadog -> `set-secrets.sh <vault> rotate datadog-api-key` -> wait for / force pick-up in agents (Helm secret `obs-kubernetes`, VM extensions `obs-hosts`), Fluent Bit sidecars, aggregator, OTel gateway, ACI sidecar (re-apply `deploy-partner-sim`) -> confirm the telemetry canary and `pipeline.*` monitors are green -> revoke the old key in Datadog |
| `datadog-app-key` | Datadog org settings | used only by the pipeline (Datadog provider, telemetry verifier, DORA events): rotate, run a `drift`-mode pipeline to confirm, revoke the old key |
| `datadog-client-token` | Datadog RUM application | browser-facing by design; RUM client token is also published in the `obs-prereqs` contract. Recreate via `obs-prereqs` and redeploy the frontend (`deploy-frontend` re-renders `config.json`) |
| `fault-token` | generated | `set-secrets.sh <vault> generate fault-token` then restart/redeploy consumers (all HTTP services + hello-traffic) |
| `dbm-mysql-password` | generated | `rotate`, then `ALTER USER 'datadog'@'%' IDENTIFIED BY '<new>'` on the MySQL server (grant script `platform/data/mysql/scripts/grant-db-users.sql`), then restart the DBM agent |
| `dbm-sqlvm-password` | generated | `rotate`, then `ALTER LOGIN datadog WITH PASSWORD = '<new>'` on the SQL VM, restart the agent |
| `sqlvm-dbadapter-password` | `platform-db-sqlvm` | bump `secret_version` in `components.platform-db-sqlvm` (written write-only to Key Vault), apply, re-run the adapter's VMSS install |
| `sqlvm-admin-password`, `documentdb-admin-password`, `cassandra-mi-admin-password` | `random_password` in the platform data roots | bump `secret_version` -> new value in state and Key Vault; apply |
| MySQL / HorizonDB admin passwords | ephemeral, write-only (`administrator_password_wo`) | bump `admin_password_version`, apply (never in state) |
| Cosmos Mongo / Cassandra / Gremlin keys | stored out-of-band (`cosmos-mongo-connection-string`, `cosmos-cassandra-password`, `cosmos-gremlin-key`) | `az cosmosdb keys regenerate --key-kind secondary`, store, restart adapters, then regenerate primary |
| `fluentbit-shared-key` | set out-of-band | forward-protocol shared key between sidecars (`sidecar-forward.yaml`) and the aggregator: rotate, then restart aggregator and forwarders together (mismatch drops forwarded logs) |
| `eventhub-fluentbit-listen` | written by `obs-telemetry-transport` from the listen authorization rule | `az eventhubs namespace authorization-rule keys renew` for `fluent-bit-listen`, then bump the write-only `value_wo_version` (module code) / re-apply transport; restart the aggregator |
| Datadog Azure integration client secret (FED / sovereign only) | created out of band (`bootstrap/README.md`) | `az ad app credential reset ...` piped to `az keyvault secret set` (never in Terraform) |
| Federated credentials (pipeline, Datadog Secretless) | no secret | issuer/subject changes only: update `components.bootstrap.federated_credentials`, re-run bootstrap |

## Secrets that land in Terraform state (accepted, documented)

State is in the private, Entra-only, versioned state account; treat it as secret. Items: `random_password` admin
passwords (SQL VM, DocumentDB, Cassandra MI, VM / Service Fabric break-glass), Event Hubs authorization rule keys
(`obs-telemetry-transport`), the Logic Apps Standard storage access key read at plan time (`deploy-logicapps` fallback),
`fault-token` and `datadog-api-key` read by `deploy-partner-sim` at plan time. List: [known limitations](../known-limitations.md#secrets-in-terraform-state).
