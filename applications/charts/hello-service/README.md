# hello-service — generic Helm chart for Enterprise Hello workloads

- **Owner**: applications layer (deployment engineering). **Status** (ADR-0001 §11): **locally-verified** —
  `helm lint --strict`, `helm template` + `kubeconform -strict` (Kubernetes 1.36.0 schemas, the platform-aks default),
  pytest assertions (`tests/charts`) and a kind v1.36.4 smoke (install, probes, BFF → catalog, upgrade, rollback).
  Not deployed to AKS/ARO from this sandbox (no Azure credentials).
- **Chart version** `2.1.1` (2.1.1: comments/docs only - log-collector wording for observability 4.0.0, rendered output unchanged apart from a YAML comment; 2.1.0: additive `service.tags` (tag policy), `telemetry.agentLogSource`, `telemetry.singleStepInstrumentation` for the Datadog fleet collection; 2.0.0: Key Vault / CSI removed, secrets as DSV references - breaking values change) (semver of the chart, independent of the applications). The application version is
  `service.version` (set per release by the deployer); `appVersion` is informational only (`helm package --app-version` may override it).
- **Engines**: Helm 4 CLI (pinned `v4.3.0`) and the Terraform `hashicorp/helm` 3.3 provider (Helm v3 SDK); rendering is
  tested to be identical with Helm `v3.22.0`. `kubeVersion: >=1.30.0-0`.

## Why one generic chart (and no umbrella chart)

Every Enterprise Hello workload on Kubernetes has the same shape (digest-pinned image, workload identity, the
instrumentation contract env, hardened pod, probes, PDB/HPA), so one chart with three `kind`s replaces per-service
manifests. An umbrella chart (`enterprise-hello` with aliased `hello-service` dependencies) was **rejected**:

- one release per workload gives independent upgrade, `helm rollback` and failure blast radius; an umbrella makes a
  bad catalog image roll back the BFF too, and one slow rollout time out all workloads;
- Terraform already composes the set (`for_each` over `settings.apps`) with values from typed contracts; an umbrella
  would duplicate that composition in YAML and add `helm dependency update`/lock/packaging steps;
- the same chart is reused unchanged on ARO (`deploy-aro.sh`) and kind, which an umbrella tied to the AKS set is not.

## What it renders

| `kind` | Objects |
|---|---|
| `deployment` (HTTP service) | Deployment, ServiceAccount, Service (ClusterIP or internal LoadBalancer), PDB, HPA, optional Ingress (app routing), Route (OpenShift), NetworkPolicy |
| `worker` (background consumer) | Deployment with a `health` port (probes), ServiceAccount, PDB, HPA, optional NetworkPolicy — no Service/Ingress |
| `cronjob` (scheduled job) | CronJob (`restartPolicy: Never`, bounded runtime/history), ServiceAccount — no probes/Service/PDB/HPA |

Built in (not configurable): `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`runAsNonRoot`, `/tmp` emptyDir, `enableServiceLinks: false`, RollingUpdate `maxSurge 1 / maxUnavailable 0`,
selector `app.kubernetes.io/name` only (immutable; identical to the pre-Helm objects so they can be adopted).

**Env order**: `DD_AGENT_HOST` (downward API `status.hostIP`, node-local Datadog Agent) first, then the chart-owned
`DD_ENV`/`DD_SERVICE`/`DD_VERSION` (= the `tags.datadoghq.com/*` labels), `AZURE_CLIENT_ID`, `FAULTS_ENABLED`, `DSV_*`, `PORT`,
`LOG_FILE_PATH` (only with `logFile.enabled`), then `env` sorted (may reference `$(DD_AGENT_HOST)`), then secret refs.

**Labels on every object and pod**: `app.kubernetes.io/{name,instance,version,component,part-of,managed-by}`,
`helm.sh/chart`, Datadog unified service tagging `tags.datadoghq.com/{env,service,version}`, `team`, `domain`, `tier`,
`logs.datadoghq.com/source`; pods add `azure.workload.identity/use: "true"` (when `identity.workloadIdentity`),
`admission.datadoghq.com/enabled: "true"` (with `telemetry.singleStepInstrumentation`), the annotation
`ad.datadoghq.com/tags` (from `service.tags`) and the log annotation `ad.datadoghq.com/<container>.logs`:
`[{"source": <agentLogSource>, "service": <service.name>}]` when the node Datadog Agent collects the logs
(`disableAgentLogCollection: false` + `agentLogSource`, what core-aks renders under observability 4.0.0) or `"[]"`
(default, `disableAgentLogCollection: true`) when the Fluent Bit DaemonSet does (`log_pipeline = fluent_bit_direct`).

**Secrets** (chart 2.0.0, Delinea DSV - no Key Vault, no Secrets Store CSI driver): the chart never creates a `Secret`.
`secretEnv` maps names to **DSV references** (`dsv://<path>#<element>`). With `secretsMode: dsv` (default) each reference
is rendered as the env VALUE together with `DSV_TENANT/DSV_TLD/DSV_BASE_URL/DSV_AUTH` (from `dsv`) and `AZURE_CLIENT_ID`;
the application resolves it at start-up with its AKS workload identity (federated token). **Open verification**: DSV maps
Azure users by the managed identity's resource id (`xms_mirid` claim) - that it accepts a workload-identity-federated
token is not verified yet. Documented fallback `secretsMode: synced`: the Delinea DSV Kubernetes syncer (dsv-k8s)
maintains the Secret `secretsSync.secretName` (default `<fullname>-dsv`, one key per `secretEnv` name) and the chart
references it with `secretKeyRef`. `existingSecretEnv` references other Secrets created out of band (ARO, kind).
The schema accepts secret-looking names (`*PASSWORD`, `*SECRET`, `*TOKEN`, `*API_KEY`, `*ACCESS_KEY`, `*PRIVATE_KEY`,
`OTEL_EXPORTER_OTLP_HEADERS`) in `env` only with a `dsv://` value, and rejects inline credentials (`Password=`,
`AccountKey=`, `SharedAccessKey=`, `Secret=`), `@Microsoft.KeyVault(` values and Key Vault URLs.

## Values reference

Enforced by `values.schema.json` (draft-07; `additionalProperties: false` everywhere it matters).

| Key | Default | Notes |
|---|---|---|
| `kind` | `deployment` | `deployment` \| `worker` \| `cronjob` |
| `fullnameOverride` | release name | keep release name = workload name (DNS `http://<svc>.<ns>.svc.cluster.local`) |
| `service.name` / `.version` / `.env` | — **required** | DD_SERVICE / DD_VERSION / DD_ENV and UST labels; label-safe |
| `service.team` / `.domain` / `.tier` / `.logsSource` / `.partOf` | `""` / `enterprise-hello` | ADR-0001 §7 tags, log source label |
| `service.tags` | `{}` | other tag-policy tags → pod annotation `ad.datadoghq.com/tags` |
| `image.repository` | — **required** | `<registry>/<repo>`, no tag |
| `image.digest` | — **required** | `sha256:<64 hex>`; `image.tag` is **rejected** |
| `image.pullPolicy` | `IfNotPresent` | digest-pinned, so this can never run another image |
| `imagePullSecrets`, `command`, `args` | `[]` | `args`/`command` e.g. the job sub-command |
| `identity.clientId` | — **required** | UUID of the user-assigned identity (`AZURE_CLIENT_ID`) |
| `identity.tenantId` | `""` | SA annotation `azure.workload.identity/tenant-id` |
| `identity.workloadIdentity` | `true` | SA client-id annotation + pod label + projected token; `false` on ARO/kind |
| `serviceAccount.create` / `.name` / `.annotations` | `true` / fullname / `{}` | SA has `automountServiceAccountToken: false` |
| `port` | `8080` | `PORT`; worker: health port (8081 for hello-worker) |
| `env` | `{}` | chart-owned names (incl. `DSV_*`, `DD_API_KEY`) rejected; secret-looking names only with a `dsv://` value; inline credentials / Key Vault references rejected |
| `secretEnv` | `{}` | name → `dsv://<path>#<element>` (literals and Key Vault ids rejected) |
| `dsv.{tenant,tld,baseUrl,auth}` | `"", com, "", azure` | DSV runtime env for the app; `secretsMode: dsv` needs tenant or baseUrl and `identity.workloadIdentity` |
| `secretsMode` / `secretsSync.secretName` | `dsv` / `<fullname>-dsv` | `synced` = dsv-k8s syncer Secret via `secretKeyRef` (fallback) |
| `existingSecretEnv` | `{}` | name → `{secretName, key}` |
| `telemetry.agentHostFromHostIP` | `true` | `DD_AGENT_HOST` from `status.hostIP` |
| `telemetry.disableAgentLogCollection` | `true` | `ad.datadoghq.com/<c>.logs: "[]"` (Fluent Bit DaemonSet collects) |
| `telemetry.agentLogSource` | `""` | with `disableAgentLogCollection: false`: Agent log source (`ad.datadoghq.com/<c>.logs`) |
| `telemetry.singleStepInstrumentation` | `false` | pod label `admission.datadoghq.com/enabled: "true"` (Datadog SSI) |
| `logFile.enabled` / `.path` / `.sizeLimit` | `false` | `LOG_FILE_PATH` on an emptyDir (sidecar/host tailers only; off on AKS) |
| `faults.enabled` | **`false`** | `FAULTS_ENABLED`; `true` requires `FAULT_TOKEN` in `secretEnv` or `existingSecretEnv` |
| `resources.requests.{cpu,memory}`, `resources.limits.memory` | 100m/192Mi, 512Mi (cpu 500m) | **required** (null-ing them fails) |
| `replicas` | `1` | only when `autoscaling.enabled: false` (≤ 20) |
| `autoscaling.{enabled,minReplicas,maxReplicas,targetCPUUtilizationPercentage}` | `true,1,3,70` | `maxReplicas` ≤ 20 (schema ceiling); Deployment omits `spec.replicas` (HPA owns it) |
| `podDisruptionBudget.{enabled,maxUnavailable}` | `true, 1` | deployment/worker |
| `probes.startup/liveness/readiness` | `/healthz`, `/healthz`, `/readyz` | periods/thresholds configurable |
| `k8sService.{type,port,internalLoadBalancer,annotations}` | `ClusterIP, 80, false` | `internalLoadBalancer` → `service.beta.kubernetes.io/azure-load-balancer-internal` |
| `ingress.{enabled,className,host,path,annotations}` | `false`, `webapprouting.kubernetes.azure.com` | AKS application routing add-on |
| `ingress.tls.{enabled,secretName}` | `true`, `<name>-tls` | existing TLS Secret (dsv-k8s syncer or cert-manager); no Key Vault certificate sync |
| `openshift.enabled` | `false` | drops `runAsUser/runAsGroup/fsGroup` (SCC assigns) |
| `openshift.route.{enabled,host,tls}` | `false`, edge + Redirect | `route.openshift.io/v1` Route instead of Ingress |
| `networkPolicy.{enabled,allowFromNamespaces,allowFromCIDRs}` | `false` | ingress to the app port from the namespace, listed namespaces and CIDRs |
| `podSecurityContext` | `runAsNonRoot: true`, seccomp `RuntimeDefault` | `runAsNonRoot` must stay `true`; no fixed UID |
| `tmp.sizeLimit`, `terminationGracePeriodSeconds`, `revisionHistoryLimit` | `256Mi`, `30`, `5` | |
| `topologySpread.{enabled,hostnameSkew,zoneSpread}` | `true, 1, false` | `ScheduleAnyway` |
| `podLabels`, `podAnnotations`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName` | empty | |
| `cronjob.{schedule,timeZone,concurrencyPolicy,...}` | `Forbid`, backoff 2, deadline 900 s, TTL 1 h | `schedule` **required** for `kind: cronjob` |

## Examples (`examples/`, not packaged)

| File | Workload |
|---|---|
| `aks-bff.yaml`, `aks-orders-api.yaml`, `aks-catalog-api.yaml`, `aks-worker.yaml` | exactly what `applications/deployments/core-aks` renders for its test fixture (drift-checked by `tests/charts/test_deploy_roots_values.py`) |
| `aro-catalog-api.yaml` | hello-catalog-api on ARO (Route, SCC-assigned UID, existing DB Secret) |
| `aks-jobs-cronjob.yaml` | the `cronjob` kind (hello-jobs reconcile trigger) — optional, jobs run on ACA today |
| `kind-bff.yaml`, `kind-catalog-api.yaml` | local kind smoke |

```bash
helm lint --strict applications/charts/hello-service -f applications/charts/hello-service/examples/aks-bff.yaml
helm template hello-bff applications/charts/hello-service -n hello -f applications/charts/hello-service/examples/aks-bff.yaml
helm upgrade --install hello-worker applications/charts/hello-service -n hello \
  -f applications/charts/hello-service/examples/aks-worker.yaml \
  --set image.digest=sha256:<64 hex> --set service.version=<build tag> \
  --rollback-on-failure --wait --timeout 10m --history-max 10       # Helm 3: --atomic instead of --rollback-on-failure
```

## How it is used

- **AKS** — `applications/deployments/core-aks`: one `helm_release` per workload (`atomic`, `wait`, `cleanup_on_fail`,
  `timeout` 600 s, `max_history` 10, `lint`), values = `yamlencode()` of a typed object built from the contracts
  (platform-aks workload identities, foundation-identity v2 DSV references, the instrumentation contract, artifacts).
  Chart source: this directory by default; `settings.helm.chart_repository = "oci://<acr>/helm"` +
  `chart_version` consume the published chart instead.
- **ARO** — `applications/deployments/specialized` renders the values into its contract (`aro.helm.values`);
  `scripts/deploy-aro.sh` runs `helm upgrade --install` after `oc login` (Terraform holds no OpenShift credentials).
- **Applications pipeline** (`pipelines/templates/helm-charts.yml` → `tools/deploy/charts.py`): Validate stage
  `helm lint --strict` + `helm template | kubeconform` for every `examples/*.yaml`; Build stage packages a
  content-addressed version `<Chart.version>+src<sha12 of the chart files>` and pushes it to
  `oci://<acr>.azurecr.io/helm` (ACR repository `helm/hello-service`; OCI tags show `+` as `_`). Equivalent commands:

```bash
python3 -m pytest tests/charts -q                     # lint/template/kubeconform(1.36)/schema + TF-rendered values
helm package applications/charts/hello-service --version "2.1.1+src<sha12>" -d out/charts
az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken \
  | helm registry login "$ACR_NAME.azurecr.io" --username 00000000-0000-0000-0000-000000000000 --password-stdin
helm push out/charts/hello-service-2.1.1+src<sha12>.tgz "oci://$ACR_NAME.azurecr.io/helm"
```

  To deploy the published chart from core-aks set `settings.helm.chart_repository = "oci://<acr>.azurecr.io/helm"` and
  `chart_version` to the exact packaged version (from the build's `charts.json`). Bump `version` in `Chart.yaml` for
  every breaking values change (MAJOR) or addition (MINOR); the content hash already separates any two contents.

## Upgrade and rollback

```bash
helm -n hello history hello-bff                      # revisions (max_history 10)
helm -n hello rollback hello-bff <revision> --wait   # break-glass, one workload only
helm -n hello get values hello-bff                   # values of the running revision
```

The normal rollback is to re-run the deployment with the previous image digest (Terraform re-applies the release,
keeping state and cluster in sync). After a break-glass `helm rollback`, re-apply the previous digest through the
pipeline so the next `terraform plan` shows no drift. A failed upgrade rolls back by itself (`atomic` /
`--rollback-on-failure`). Adopting objects created by the pre-Helm core-aks root: one apply with
`settings.helm.take_ownership = true` (Helm `--take-ownership`); selectors are unchanged, so Deployments are not recreated.

## Accepted static-analysis findings (checkov kubernetes on the rendered examples: 706 passed, 25 failed)

| Check | Why accepted |
|---|---|
| CKV_K8S_40 high UID | images declare numeric non-root users (1654/10001); a pinned UID would break OpenShift SCC ranges — set `podSecurityContext.runAsUser` if required |
| CKV2_K8S_6 NetworkPolicy | opt-in (`networkPolicy.enabled`): the internal LB / app routing source ranges are environment-specific |
| CKV_K8S_35 secrets as env | the application contract reads `FAULT_TOKEN` from env; the env value is a `dsv://` reference resolved by the app (or a dsv-k8s syncer Secret in secretsMode synced) |
| CKV_K8S_38 SA token mounted | required by AKS workload identity; disabled when `identity.workloadIdentity: false` |

Docs: https://helm.sh/docs/topics/charts/ , https://helm.sh/docs/topics/registries/ ,
https://learn.microsoft.com/azure/container-registry/container-registry-helm-repos ,
https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster ,
https://learn.microsoft.com/azure/aks/app-routing ,
https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ ,
https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html
