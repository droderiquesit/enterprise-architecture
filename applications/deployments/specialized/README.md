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
  edge-TLS Route instead of an Ingress). **Secrets as on AKS** (ADR-0001 section 14, chart `secretsMode=dsv`,
  `DSV_AUTH=azure`, `dsv` from the transport contract): the app reads Delinea DSV directly with its **Entra workload
  identity** — `platform-aro` federates the `foundation-identity` `hello-catalog-api` identity with the managed-identity
  cluster's OIDC issuer for `system:serviceaccount:hello:hello-catalog-api` (same ownership rule as `platform-aks`,
  ADR-0001 section 3) and publishes it as contract `workload_identities`; this root sets the service account
  (`azure.workload.identity/client-id`, tenant id) and the pod label `azure.workload.identity/use=true`, and the OpenShift
  pod-identity webhook (`openshift-cloud-credential-operator`) injects `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
  `AZURE_FEDERATED_TOKEN_FILE` and the projected token (a `projected` volume, allowed by `restricted-v2`). No Key Vault,
  no Kubernetes Secret, no dsv-k8s syncer. `scripts/deploy-aro.sh`
  runs `helm upgrade --install --rollback-on-failure` (Helm 3: `--atomic`) `--wait --history-max 10`. Logs
  (observability 4.1.0): the Datadog node Agent of `obs-kubernetes-aro` collects the container's stdout - the values
  follow the fleet log collector as on AKS (`telemetry.disableAgentLogCollection` / `agentLogSource`, SSI label).
  **Prerequisite**: an OpenShift login — the pipeline provides `OC_TOKEN` (deployer service account / Entra-integrated
  identity; kubeadmin via `az aro list-credentials` is not used) and the script runs `oc login --server <api> --token`;
  `--dry-run` without `OC_TOKEN` only renders the chart. PG/Redis env comes from `settings.aro_catalog_env` (non-secret;
  secret-looking keys are rejected) and secret settings from `settings.aro_catalog_secret_env` as `dsv://` references
  (`{PG_PASSWORD = "dsv://eh/dev/<name>#value"}`; the `hello-catalog-api` identity must be a reader of the path in
  `foundation/identity`); `settings.aro_replicas` (2). `status.aro` is `blocked` when platform-aro publishes no
  federated `hello-catalog-api` workload identity, its namespace differs from `settings.aro_namespace` (`hello`), or the
  digest-pinned image is missing.
- **Confidential VM** — `hello-worker` via managed run command (`install-hello-worker-cvm`, same `vm-script` as vm-workloads).
- **Automation** — `azurerm_automation_runbook` `hello-health-probe` (`Python3`, stdlib-only script in `templates/health-probe.py`)
  + `azurerm_automation_job_schedule` on the platform schedule with `probe_urls`.
- **Consumed contracts** (catalog/components.yaml): obs-telemetry-transport, foundation-identity; optional
  platform-servicefabric, platform-aro (1.1.0: `workload_identities`, `oidc_issuer_url`), platform-specialized-compute, platform-messaging, platform-db-table-storage.
- **Produced contract**: `deploy-specialized`: `service_fabric`, `aro`, `apps`, `status`.

## Rollback
SF: `sfctl application upgrade` to the previous type version (auto-rollback on health failure). ARO: automatic rollback of a
failed upgrade; manual `helm -n hello rollback hello-catalog-api <revision> --wait` or re-apply the previous digest. CVM: previous package. Runbook: previous commit.

## Cost
No billable resources of its own beyond the runbook (Automation free minutes cover an hourly probe).
