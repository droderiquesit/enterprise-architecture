# deploy-specialized — Service Fabric, ARO, confidential VM, Automation

- **Owner**: applications layer. **Status**: implemented (mock tests); SF/ARO deploy scripts syntax-checked only.
- **Service Fabric managed cluster** — `hello-inventory-api` guest executable. azurerm 5.9 has **no** Service Fabric
  application/application-type resources, so Terraform renders `ApplicationManifest.xml` / `ServiceManifest.xml` (env vars,
  endpoint port from platform-servicefabric `app_port`) into the contract and `scripts/deploy-sf.sh` uploads/provisions/
  upgrades with `sfctl` (monitored upgrade, FailureAction=Rollback). The cluster admin client certificate is read from
  Delinea DSV by the pipeline at deploy time (not in state).
- **ARO** — `hello-catalog-api` with the shared Helm chart [`applications/charts/hello-service`](../../charts/hello-service/README.md):
  Terraform renders the release values into the contract (`aro.helm.{release,chart,chart_path,values}`) with OpenShift
  settings (`openshift.enabled`: no fixed `runAsUser` — the restricted-v2 SCC assigns the UID; `openshift.route.enabled`:
  edge-TLS Route instead of an Ingress; no AKS workload identity webhook, so no `dsv://` settings: secrets come from Secrets synced from Delinea DSV by the dsv-k8s syncer, chart `secretsMode=synced`, `DSV_AUTH=none`). `scripts/deploy-aro.sh`
  runs `helm upgrade --install --rollback-on-failure` (Helm 3: `--atomic`) `--wait --history-max 10`.
  **Prerequisite**: an OpenShift login — the pipeline provides `OC_TOKEN` (deployer service account / Entra-integrated
  identity; kubeadmin via `az aro list-credentials` is not used) and the script runs `oc login --server <api> --token`;
  `--dry-run` without `OC_TOKEN` only renders the chart. PG/Redis env comes from `settings.aro_catalog_env` (non-secret;
  secret-looking keys are rejected) and secrets from existing Secrets via `settings.aro_secret_env`
  (`{PG_PASSWORD = {secretName, key}}`); `settings.aro_replicas` (2). `status.aro` is `blocked` when the
  foundation-identity `hello-catalog-api` identity or a digest-pinned image is missing.
- **Confidential VM** — `hello-worker` via managed run command (`install-hello-worker-cvm`, same `vm-script` as vm-workloads).
- **Automation** — `azurerm_automation_runbook` `hello-health-probe` (`Python3`, stdlib-only script in `templates/health-probe.py`)
  + `azurerm_automation_job_schedule` on the platform schedule with `probe_urls`.
- **Consumed contracts** (catalog/components.yaml): obs-telemetry-transport, foundation-identity; optional
  platform-servicefabric, platform-aro, platform-specialized-compute, platform-messaging, platform-db-table-storage.
- **Produced contract**: `deploy-specialized`: `service_fabric`, `aro`, `apps`, `status`.

## Rollback
SF: `sfctl application upgrade` to the previous type version (auto-rollback on health failure). ARO: automatic rollback of a
failed upgrade; manual `helm -n hello rollback hello-catalog-api <revision> --wait` or re-apply the previous digest. CVM: previous package. Runbook: previous commit.

## Cost
No billable resources of its own beyond the runbook (Automation free minutes cover an hourly probe).

## Test
`bash tools/validate/terraform.sh applications/deployments/specialized` (fmt -check, init -backend=false, validate,
`terraform test` with mock providers: `tests/specialized.tftest.hcl`).

Docs: https://learn.microsoft.com/azure/service-fabric/service-fabric-guest-executables-introduction , https://learn.microsoft.com/azure/openshift/ ,
https://learn.microsoft.com/azure/automation/automation-runbook-types
