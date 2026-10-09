# deploy-core-aks — core services on AKS

- **Owner**: applications layer. **Status**: implemented (mock tests); not deployed.
- **Purpose**: `hello-bff`, `hello-orders-api`, `hello-catalog-api`, `hello-worker` in namespace `hello`, deployed as
  **one Helm release per workload** from the repository chart
  [`applications/charts/hello-service`](../../charts/hello-service/README.md) (Deployment, workload-identity
  ServiceAccount, Service, PodDisruptionBudget, HPA with ceilings, optional Ingress/NetworkPolicy).
  The root owns the namespace (Pod Security `restricted`) and renders each release's values from the contracts.
- **Providers**: azurerm (cluster endpoint/CA via `data.azurerm_kubernetes_cluster`, i.e. listClusterUserCredential;
  local accounts are disabled so no credentials are returned) + **helm 3.3** (Helm v3 SDK; `helm_release`) +
  kubernetes 3.3 (namespace, BFF load balancer address), both with **kubelogin exec**
  (`settings.kubelogin_mode`: `azurecli` (pipeline AzureCLI task / developer) or `workloadidentity`).
  The private API server must be reachable (foundation-deploy-agents in the VNet).
- **Consumed contracts**: platform-aks, platform-shared, platform-messaging, platform-db-sql, platform-db-postgresql,
  obs-telemetry-transport, foundation-identity; optional platform-db-redis, obs-kubernetes (not read today).
- **Produced contract**: `deploy-core-aks`: `apps.<svc>.{id (<cluster id>/namespaces/hello/deployments/<svc>), url,...}`,
  `public_api.origin`, `endpoints` (BFF only), `idle_behavior` (no scale-to-zero), `secrets.mechanism`, `exposure`,
  `helm.{chart, chart_source, chart_version, releases}` (additive; shape of the existing keys unchanged).

## Helm releases
`helm_release.app[<svc>]`: release name = workload name, namespace `hello` (created by this root, `create_namespace =
false`), `values = [yamlencode(<typed object>)]`, `atomic = true` (failed upgrade → automatic rollback),
`wait = true` (readiness-gated), `cleanup_on_fail = true`, `timeout = settings.helm.timeout_seconds` (600),
`max_history = settings.helm.max_history` (10), `lint = true` (chart lint + `values.schema.json` at plan).
Preconditions: digest-pinned image per workload. The chart schema additionally rejects tags, a missing client id,
missing resources, literal secret-looking env (only `dsv://` references allowed), Key Vault references and `faults.enabled` without a `FAULT_TOKEN` reference.

| Values key | Source |
|---|---|
| `service.{name,version,env,team,domain,tier,logsSource}` | workload, `artifacts` version → tag → digest prefix, `environment.name`, service-meta, instrumentation labels |
| `image.{repository,digest}` | `var.artifacts[svc-*].image` split at `@` |
| `identity.clientId`, `serviceAccount.name` | platform-aks `workload_identities.<svc>` |
| `env` | `modules/app-env` (instrumentation contract + service env) minus the chart-owned `DD_ENV/DD_SERVICE/DD_VERSION/AZURE_CLIENT_ID/FAULTS_ENABLED/PORT/LOG_FILE_PATH/DSV_*` and the secret settings |
| `secretEnv` | `dsv://` references: foundation-identity v2 `secrets.refs["fault-token"]` (HTTP services) |
| `dsv`, `secretsMode` | DSV endpoint from the transport contract `secrets`; `settings.secrets_mode` (`dsv` default, `synced` fallback) |
| `faults.enabled` | `settings.faults_enabled` **and** a FAULT_TOKEN reference (else false) |
| `resources`, `autoscaling` | `settings.apps.<svc>`, `max_replicas` capped by `settings.replica_ceiling` (≤ 20) |
| `k8sService`, `ingress` | `settings.exposure` (`internal-lb` → LoadBalancer + internal annotation on the BFF; `app-routing` → Ingress) |
| `networkPolicy` | `settings.network_policy_enabled` (+ `network_policy_allow_cidrs` for the BFF) |

Chart source: the repository chart (default, always in step with this root) or the chart the applications pipeline
published to ACR: `settings.helm = { chart_repository = "oci://<acr login server>/helm", chart_version = "2.0.0" }`
(the agent runs `helm registry login` with an `az acr login --expose-token` token before `terraform plan`).

## App settings
Same service env as deploy-core-aca plus: `DD_AGENT_HOST` from `status.hostIP` (first env var) and
`OTEL_EXPORTER_OTLP_ENDPOINT=http://$(DD_AGENT_HOST):4317` (gRPC), no `LOG_FILE_PATH` (stdout → Fluent Bit
DaemonSet), unified service labels `tags.datadoghq.com/*`, pod annotation `ad.datadoghq.com/<c>.logs=[]` (Agent must
not ship the same logs). Worker: `SB_TOPIC`, `SB_SUBSCRIPTION=notifications`, `HEALTH_PORT=8081`, `TABLE_MODE=memory`
(this root does not consume platform-db-table-storage). Python services get `AZURE_CREDENTIAL_MODE=workload_identity`.

**Secrets** (Delinea DSV, ADR-0001 §14; no Key Vault, no Secrets Store CSI driver): `settings.secrets_mode = dsv`
(default) renders each secret setting as an env value holding its `dsv://` reference plus the `DSV_*` env; the app
resolves it at start-up with its workload identity (`AZURE_CLIENT_ID` + federated token). **Open verification**: DSV maps
Azure users by the identity's resource id (`xms_mirid`); that DSV accepts a token obtained through AKS workload-identity
federation is not verified. Fallback `secrets_mode = synced`: the chart reads the Secret `<svc>-dsv` (one key per setting)
maintained by the Delinea DSV Kubernetes syncer (dsv-k8s, operated outside Terraform).

**Exposure**: platform-aks does not enable the application routing add-on (`web_app_routing`), so the default
`exposure.mode = internal-lb` publishes hello-bff on an internal Azure Load Balancer (HTTP, VNet only). With the add-on
enabled, `exposure.mode = app-routing` creates an Ingress (`webapprouting.kubernetes.azure.com`) with TLS from the existing
Secret `exposure.tls_secret_name` (e.g. synced from DSV by dsv-k8s, or cert-manager); no Key Vault certificate sync.

## Settings
`kubelogin_mode`, `namespace`, `faults_enabled`, `log_level`, `trace_sample_ratio`, `replica_ceiling` (6, ≤ 20),
`secrets_mode`, `exposure.{mode,host,tls_secret_name}`, `cors_allowed_origins`, `auth_mode`, `inventory_api_url`, `adapters`,
`apps.<svc>.{enabled,min_replicas (1),max_replicas (3),cpu/memory requests+limits,target_cpu}`,
`helm.{chart_repository (null = repo chart), chart_version, timeout_seconds (600), max_history (10), take_ownership (false)}`,
`network_policy_enabled` (false), `network_policy_allow_cidrs` ([]).

## Rollback
Re-run the deployment with the previous image digests (helm upgrade, RollingUpdate maxUnavailable 0, readiness-gated;
a failing upgrade is rolled back automatically by `atomic`). Releases are independent: one workload can be rolled back
without touching the others. Break-glass: `helm -n hello history <svc>` + `helm -n hello rollback <svc> <revision> --wait`,
then re-apply the previous digest through the pipeline so Terraform state matches the cluster.

## Migration from the pre-Helm version of this root
Earlier revisions managed `kubernetes_deployment_v1`/`service_v1`/`service_account_v1`/`pod_disruption_budget_v1`/
`horizontal_pod_autoscaler_v2`/`ingress_v1`/`kubernetes_manifest` directly. No environment was deployed from this
repository, so the switch is clean. For a cluster that runs the old objects: remove them from state
(`terraform state rm` of those addresses — not destroy), then apply once with `settings.helm.take_ownership = true`
(Helm adopts the existing objects; the selector `app.kubernetes.io/name` is unchanged, so pods are not recreated),
then set it back to `false`.

## Smoke
`scripts/smoke.sh`: in-cluster URLs through `az aks command invoke` (`curl http://<svc>.hello.svc.cluster.local/readyz`),
BFF via the internal LB address from the deploy agents.

## Cost
No Azure resources of its own (pods run on the platform-aks node pool). Internal LB: Standard LB rules ≈ $18/month.

## Teardown
Destroys Kubernetes objects and namespace `hello`; no persistent volumes.

## Security
Pod Security `restricted` labels, non-root, read-only root FS (+ `/tmp` emptyDir), drop ALL capabilities,
RuntimeDefault seccomp, topology spread, `automountServiceAccountToken` only for the projected WI token — all rendered
by the chart and asserted in `tests/charts` (kind smoke installs into a `restricted` namespace).

## Limitations
- `helm_release` (`lint = true`) and the LB data source need API access during plan/apply (private cluster: run on
  foundation-deploy-agents).
- Values (non-secret) are stored in Terraform state and in the Helm release Secret (`sh.helm.release.v1.*`).
- TLS on the internal LB path is not available without the app routing add-on (requested change).

Docs: https://registry.terraform.io/providers/hashicorp/helm/3.3.0/docs/resources/release ,
https://learn.microsoft.com/azure/aks/workload-identity-overview , https://docs.delinea.com/online-help/dsv/ (Kubernetes syncer / Azure authentication) ,
https://learn.microsoft.com/azure/aks/app-routing , https://azure.github.io/kubelogin/
