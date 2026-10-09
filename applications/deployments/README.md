# applications/deployments — Enterprise Hello application deployment roots

Owner: applications layer (deployment engineering). Status (ADR-0001 §11): **implemented** — every root passes
`terraform fmt -check`, `init -backend=false`, `validate` and `terraform test` (mock providers); nothing has been
deployed from this sandbox (no Azure credentials).

Per ADR-0001 §3 these roots own the **application resources and all of their settings/env vars**: container apps and
jobs, web/function apps (incl. Flex), Kubernetes Deployments/Services/ServiceAccounts/Ingress/PDB/HPA, container
groups, the Static Web App, VM/VMSS install run commands/extensions, Logic App workflows, Automation runbooks.
Platforms, databases, RBAC data-plane grants, diagnostic settings and telemetry agents are owned elsewhere.

| Root | Component | Workloads (catalog/architecture-matrix.yaml) |
|---|---|---|
| [core-aks](core-aks/README.md) | deploy-core-aks | bff, orders-api, catalog-api, worker on AKS (namespace `hello`) |
| [core-aca](core-aca/README.md) | deploy-core-aca | bff (external), orders-api, catalog-api (internal) on Container Apps |
| [frontend](frontend/README.md) | deploy-frontend | hello-frontend on Static Web Apps + runtime config.json |
| [durable](durable/README.md) | deploy-durable | hello-durable on Flex Consumption (+ Windows Consumption Reconciliation) |
| [functions](functions/README.md) | deploy-functions | hello-functions on Premium / Dedicated / Functions-on-ACA |
| [partner-sim](partner-sim/README.md) | deploy-partner-sim | hello-partner-sim on ACI |
| [dbadapters](dbadapters/README.md) | deploy-dbadapters | hello-dbadapter-<family> per enabled DB family |
| [appservice](appservice/README.md) | deploy-appservice | inventory-api Windows code (+ Windows container, catalog Linux container) |
| [jobs](jobs/README.md) | deploy-jobs | ACA jobs (seed, reconcile, traffic, batch-items) + Batch submission script |
| [vm-workloads](vm-workloads/README.md) | deploy-vm-workloads | worker on Linux VM / VMSS Flexible, inventory-api Windows service |
| [logicapps](logicapps/README.md) | deploy-logicapps | Logic Apps Consumption + Standard |
| [specialized](specialized/README.md) | deploy-specialized | Service Fabric, ARO, confidential VM, Automation runbook |

## Shared modules (`modules/`)

| Module | Kind | Purpose |
|---|---|---|
| `app-env` | pure | Wraps `observability/modules/instrumentation` (instrumentation contract) and adds identity (`AZURE_CLIENT_ID`, `AZURE_CREDENTIAL_MODE`), `FAULTS_ENABLED` (default false), `FAULT_TOKEN` as a Key Vault reference, `PORT`, `LOG_LEVEL`, `GIT_COMMIT`. Outputs env, secret env (name → versionless secret id), App Service settings (`@Microsoft.KeyVault(SecretUri=...)`), Container Apps sidecar patch, ACI sidecar, Kubernetes labels. |
| `container-app` | azurerm | One Container App: user-assigned identity (ACR pull + Key Vault secret refs), digest-pinned image, `/healthz` liveness/startup + `/readyz` readiness, HTTP scale rule, Fluent Bit sidecar on a shared EmptyDir, multiple-revision traffic weights. |
| `web-app` | azurerm | Linux/Windows web app (code or container), Key Vault reference identity, VNet integration, health check, private endpoint or deny-by-default access restrictions, `staging` slot when the SKU supports slots. |
| `vm-script` | pure | Renders the Linux install script for run commands / CustomScript: package read with the host's managed identity (IMDS token, no SAS), sha256 check, env file, secrets fetched from Key Vault **on the host** (never in state), health check + rollback. |
| `service-meta` | pure | Team/domain/tier/owner/runtime/artifact per service (mirrors observability onboarding metadata). |

## Conventions (all roots)

- **Inputs**: `environment`, `settings` (typed, defaults), upstream contracts as typed variables (`contracts.tf`,
  optional producers `default = null` with count/for_each guards), `artifacts` (map keyed by artifact component id,
  written by `tools/deploy/artifacts.py tfvars`). Images must match `<registry>/<repo>@sha256:<64 hex>` — the variable
  validation rejects tags (`:latest`). `version`/`commit` are optional (the build metadata has `tag`); DD_VERSION =
  `version` → `tag` → digest prefix.
- **Telemetry** (ADR-0001 §10): OTel env from the instrumentation contract; OTLP → node agent on AKS
  (`status.hostIP` downward API) / localhost agent on VMs / OTel gateway elsewhere (HTTP for Functions).
  Logs: ACA + ACI → Fluent Bit sidecar tailing `LOG_FILE_PATH=/var/log/app/app.log` on a shared EmptyDir;
  AKS → Fluent Bit DaemonSet; App Service / Functions / Logic Apps → diagnostic settings (no sidecar);
  VM/VMSS → host Fluent Bit service; ACA **jobs** → stdout + ContainerAppConsoleLogs (a sidecar would never exit).
- **Secrets**: Key Vault versionless ids only. ACA `secret { key_vault_secret_id, identity }`; App Service/Functions
  `@Microsoft.KeyVault(SecretUri=...)`; AKS Secrets Store CSI driver add-on (SecretProviderClass with the pod's
  workload identity); VM/VMSS fetched on the host via IMDS. **Exception**: ACI has no Key Vault references — the
  partner-sim root reads `fault-token` and `datadog-api-key` with a data source (sensitive, in the Entra-only state).
- **Contract** (`output "contract"`, schema `catalog/contracts/deploy-<id>.v1.schema.json`): `apps.<key>` =
  `{id, name, type, service, architecture, app_log_route, sidecar, url, urls{public,private}, health/readiness/version
  paths, scale_to_zero, min/max replicas, version, image, identity_name}`, `endpoints` (base URLs serving `/healthz`,
  `/readyz`, `/version` for `tools/smoke/smoke.py`), `idle_behavior.<key>.scale_to_zero` (monitoring), `deploy_steps`
  (post-apply code deployment), `rollback`. Keys ending in `_url/_endpoint/_fqdn` are avoided outside `endpoints`
  because the smoke tool probes every such key.

## Pipeline steps (`scripts/`)

| Script | Purpose |
|---|---|
| `deploy-zip.sh --contract <file|root>` | Runs `contract.deploy_steps`: `az webapp deploy` (staging slot + swap), Flex one deploy (`az functionapp deployment config show` + `az functionapp deployment source config-zip`), `az logicapp deployment source config-zip`, `az vmss update-instances`, VMSS Flex run-command rollout, SWA, Batch. Packages via `az storage blob download --auth-mode login` + sha256. |
| `deploy-swa.sh --contract <file|root>` | Writes `config.json` / `staticwebapp.config.json` / `version.json` / `healthz.json` from the contract into the bundle, gets the SWA deployment token at deploy time (`az staticwebapp secrets list`, never stored) and uploads with SWA CLI 2.0.7. |
| `smoke.sh --contract <file|root> [--jobs]` | Bounded polling of every app's health/readiness/version path (AKS in-cluster URLs via `az aks command invoke`); optional seed job execution. |

Post-apply order per root: `terraform apply` → `deploy-zip.sh` (if `deploy_steps`) → `smoke.sh`.

## Validation

```bash
for d in applications/deployments/modules/* applications/deployments/*/; do bash tools/validate/terraform.sh "$d"; done
checkov -d applications/deployments --framework terraform --quiet   # 0 failed; skips are justified inline
```

Docs: https://learn.microsoft.com/azure/container-apps/ , https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan ,
https://learn.microsoft.com/azure/aks/workload-identity-overview , https://learn.microsoft.com/azure/aks/csi-secrets-store-driver ,
https://learn.microsoft.com/azure/app-service/app-service-key-vault-references , https://learn.microsoft.com/azure/static-web-apps/
