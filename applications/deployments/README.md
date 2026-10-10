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
| [core-aks](core-aks/README.md) | deploy-core-aks | bff, orders-api, catalog-api, worker on AKS (namespace `hello`), one Helm release each |
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
| `app-env` | pure | Wraps `observability/modules/instrumentation` (instrumentation contract) and adds identity (`AZURE_CLIENT_ID`, `AZURE_CREDENTIAL_MODE`), `FAULTS_ENABLED` (default false), `FAULT_TOKEN` as a Delinea DSV reference (`dsv://...`, resolved by the app), the DSV runtime env (`DSV_TENANT/TLD/BASE_URL/AUTH`), `PORT`, `LOG_LEVEL`, `GIT_COMMIT`. Outputs env (incl. `dsv://` values), secret env (name → `dsv://` reference), App Service settings (same map, no Key Vault references), Container Apps sidecar patch (serverless-init sidecar + dsv-fetch-install init container; Fluent Bit + dsv-fetch init/refresher with `fluent_bit_direct`), ACI sidecar (Datadog Agent), Kubernetes labels/annotations, the effective log collector and APM decision. |
| `container-app` | azurerm | One Container App: user-assigned identity (ACR pull; the app and dsv-fetch read DSV with it), no Container Apps secrets except non-secret sidecar config files, digest-pinned image, `/healthz` liveness/startup + `/readyz` readiness, HTTP scale rule, the observability sidecar on a shared EmptyDir (Datadog serverless-init by default, its key read by the dsv-fetch binary an identity-free init container installs; Fluent Bit with `fluent_bit_direct`, its key written by a dsv-fetch init container on the Consumption profile or a refresher container on Dedicated profiles), multiple-revision traffic weights. |
| `web-app` | azurerm | Linux/Windows web app (code or container), user-assigned identity (no Key Vault reference identity; `@Microsoft.KeyVault(` values are rejected), VNet integration, health check, private endpoint or deny-by-default access restrictions, `staging` slot when the SKU supports slots. |
| `vm-script` | pure | Renders the Linux install script for run commands / CustomScript: package read with the host's managed identity (IMDS token, no SAS), sha256 check, env file (secret settings as `dsv://` references the service resolves at start-up), health check + rollback. |
| `service-meta` | pure | Team/domain/tier/owner/runtime/artifact per service (mirrors observability onboarding metadata). |

## Helm (Kubernetes workloads)

Every Enterprise Hello workload on Kubernetes is deployed with the generic chart
[`applications/charts/hello-service`](../charts/hello-service/README.md) (kinds `deployment`, `worker`, `cronjob`;
values contract in `values.schema.json`: digest-only images, required identity client id and resources, no plaintext
secrets, faults off by default).

| Where | How |
|---|---|
| AKS (`core-aks`) | `helm_release` per workload (hashicorp/helm 3.3), values = `yamlencode` of a typed object from the contracts; `atomic`, `wait`, `cleanup_on_fail`, `max_history 10`, `lint`; chart from the repo or `oci://<acr>/helm/hello-service:<version>` |
| ARO (`specialized`) | values rendered into the contract; `scripts/deploy-aro.sh` → `oc login` + `helm upgrade --install --rollback-on-failure --wait` |
| kind (tests) | `tests/charts/test_kind_smoke.py` (opt-in `HELLO_KIND_SMOKE=1`) |

Where Helm is **not** used, and why: Container Apps, App Service/Functions, ACI, Static Web Apps, VM/VMSS, Logic Apps,
Service Fabric and Automation are ARM resources (azurerm) or non-Kubernetes runtimes — Helm only targets Kubernetes APIs.
Chart tests: `python3 -m pytest tests/charts -q` (lint `--strict`, template, kubeconform against the AKS Kubernetes
version, rendered-manifest assertions, schema rejections, Terraform-rendered values). The applications pipeline packages
and pushes the chart (`helm package` → `helm push oci://<acr>/helm`); see the chart README.

## Conventions (all roots)

- **Inputs**: `environment`, `settings` (typed, defaults), upstream contracts as typed variables (`contracts.tf`,
  optional producers `default = null` with count/for_each guards), `artifacts` (map keyed by artifact component id,
  written by `tools/deploy/artifacts.py tfvars`). Images must match `<registry>/<repo>@sha256:<64 hex>` — the variable
  validation rejects tags (`:latest`). `version`/`commit` are optional (the build metadata has `tag`); DD_VERSION =
  `version` → `tag` → digest prefix.
- **Telemetry** (ADR-0001 §10): OTel env from the instrumentation contract; OTLP → node agent on AKS
  (`status.hostIP` downward API) / localhost agent on VMs / OTel gateway elsewhere (HTTP for Functions).
  Logs (observability 4.0.0, one collector per architecture, ADR-0001 §13): ACA → Datadog serverless-init sidecar
  tailing `LOG_FILE_PATH=/var/log/app/app.log` on a shared EmptyDir; ACI → Datadog Agent sidecar tailing the same file;
  AKS → node Datadog Agent (stdout); VM/VMSS → host Datadog Agent (app log file); App Service / Functions / Logic Apps →
  diagnostic settings (no sidecar); ACA **jobs** → stdout + ContainerAppConsoleLogs (a sidecar would never exit).
  With `log_pipeline = fluent_bit_direct` (fallback) the 2.x Fluent Bit sidecars / DaemonSet / host service collect instead.
- **Secrets** (ADR-0001 §14, Delinea DSV, no Azure Key Vault): every secret setting is a plain env var / app setting
  whose VALUE is a `dsv://<path>#<element>` reference (from `foundation_identity.secrets.refs` or a platform contract's
  `*_secret_id` field), plus `DSV_TENANT/TLD/BASE_URL/AUTH` and `AZURE_CLIENT_ID`; `hello_common` / `Hello.Common`
  resolve them at start-up with the workload's managed identity (ACA/App Service/Functions: `IDENTITY_ENDPOINT`;
  ACI/VM/VMSS: IMDS; AKS: workload identity - **unverified with DSV**, fallback chart `secretsMode=synced` with the
  Delinea dsv-k8s syncer). Third-party sidecars get their key from the static `dsv-fetch` binary (registry
  artifact `img-dsv-fetch`, `artifacts["img-dsv-fetch"]` in core-aca/dbadapters/jobs/partner-sim): an identity-free
  init container installs it; serverless-init (ACA) runs it before start and the ACI Agent uses it as its
  `secret_backend_command`. Fluent Bit fallback: dsv-fetch init container on the ACA Consumption profile, refresher
  container on Dedicated profiles and on ACI (ACI init containers have no managed identity). No secret value is in any plan or state of these roots, with one documented exception:
  logicapps' Standard host storage access key (runtime-read setting, key access required outside ASE v3).
  Host-read settings (`AzureWebJobsStorage`, trigger connections) stay identity-based - they cannot be `dsv://`.
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
python3 -m pytest tests/charts -q                                    # hello-service chart (helm + kubeconform)
```

Docs: https://learn.microsoft.com/azure/container-apps/ , https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan ,
https://learn.microsoft.com/azure/aks/workload-identity-overview , https://learn.microsoft.com/azure/container-apps/managed-identity#control-managed-identity-availability ,
https://learn.microsoft.com/azure/app-service/app-service-key-vault-references , https://learn.microsoft.com/azure/static-web-apps/
