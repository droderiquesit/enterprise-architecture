# modules/kubernetes

Installs the Datadog Agent (Helm chart `datadog` **3.253.2**: node Agent DaemonSet, Cluster Agent, cluster-checks
runners) on an **existing** cluster, optionally the Observability Pipelines Worker (`op_worker`) and - only for the
fallback log path - the Fluent Bit DaemonSet (chart `fluent-bit` **0.58.3**, image `fluent/fluent-bit:5.1.3`). Chart
versions from the chart indexes on 2026-10-09. The Agent / Cluster Agent version is **not** an input: it is the fleet
policy `agent.version` (single pin, = `versions.yaml` `images.datadog_agent`); a policy without it fails the plan.

Only `helm` and `kubernetes` resources are used. **The caller configures the providers** (host, CA, kubelogin exec
plugin; the repository's lab Kubernetes root is one example). The deploy agent needs `/bin/sh` and `awk` (post-renderer).

## Inputs (Terraform passes only these)
`cluster_name`, `identity` (tag values), `datadog {site, env, extra_tags}`, `dsv {api_key_ref, tenant|base_url, tld,
fetch_image, identity_client_id, cluster_checks_identity_client_id}`, `charts` (chart pins), `features` (flags:
`apm`, `process_collection`, `cluster_checks_runner`, `operator_subchart`, `service_discovery`, `kubelet_tls_mode`,
`is_aks`), `fleet_policy` / `tag_policy` / `log_pipeline` / `op_logs_url` / `apm`, `cluster_checks`, `op_worker`,
`fluent_bit`, and `values_overrides`.

## Chart values: three YAML layers (`helm_release.datadog.values`, later wins)
| # | Source | Content |
|---|---|---|
| 0 | `values/base.yaml` | static, reviewed defaults: OTLP receiver (hostPort 4317/4318, logs off), cluster checks on, Operator sub-chart and discovery off, requests/limits, the `dsv-fetch` emptyDir (`medium: Memory`) + mount `/opt/dsv-fetch` in agents / clusterAgent / clusterChecksRunner, dedicated runner service account |
| 1 | `local.fleet_values` (main.tf, `yamlencode`) | computed bits only: site, cluster name, tags + `podLabelsAsTags` (tag policy), log collector (Agent logs on/off, exclusions, OP Worker env), SSI targets + library versions, image tags (fleet `agent.version`) and registry (`agent.image`), Remote Configuration, kubelet TLS mode, feature flags, `clusterAgent.confd`, and the secret path (below) |
| 2.. | `values_overrides` | per-cluster YAML documents (`[file("clusters/aks-prod.yaml")]`): sizing, replicas, tolerations, extra env via `*.envDict`. Rejected by validation: `datadog.apiKey`/`apiKeyExistingSecret`/`secretBackend`/`env` and `volumes`/`volumeMounts`/`rbac.serviceAccountAnnotations` of the three Agent components (lists replace in Helm and would drop the dsv-fetch wiring) |

Output `datadog_values` is that list; `datadog_postrender_args` the post-renderer arguments.

## API key: one secret path (Delinea DSV, ADR-0001 section 14)
* The chart Secret `datadog` holds only `ENC[<dsv.api_key_ref>]`. There is **no** existing-Secret mode, no synced
  Secret for the Cluster Agent and no `DD_SECRET_BACKEND_COMMAND=""` opt-out any more.
* **Node Agent (all containers), Cluster Agent and cluster-checks runners** run `secret_backend_command =
  /opt/dsv-fetch/dsv-fetch` `agent-backend` (chart-generated `DD_SECRET_BACKEND_*` env, `DSV_*` env per component).
  The binary is the static Go `dsv-fetch` (image `dsv-fetch` >= 2.0.0, `dsv.fetch_image` digest-pinned) - no Python, so
  it also runs in the Cluster Agent image.
* **Init container `dsv-fetch-install`**: the datadog chart has no hook for extra init containers, so
  `postrender/dsv-fetch-init.sh` (Helm post-renderer, POSIX sh + awk) inserts it into the DaemonSet and both
  Deployments: `dsv-fetch install --dest /dsv-fetch-out/dsv-fetch` into the pod's in-memory emptyDir, `runAsUser: 0`
  (every Datadog container of the chart runs as root, so the file is owned by the Agent user with mode 0500), no
  capabilities, read-only root filesystem, `RuntimeDefault` seccomp. It fails the render when it does not find exactly
  `--expect` workloads (3, or 2 without runners), e.g. after a chart layout change.
* **Workload identity**: pod label `azure.workload.identity/use` (`additionalLabels`) and client-id annotations on the
  service accounts `datadog`, `datadog-cluster-agent` (`dsv.identity_client_id`) and `datadog-cluster-checks`
  (`dsv.cluster_checks_identity_client_id`, default the same identity - e.g. the DBM identity that reads the DB
  password paths and logs in to Entra-enabled databases). The caller federates the identities with these service
  accounts.
* **Cluster checks** (`cluster_checks`, e.g. DBM from `modules/dbm`): passwords only as `ENC[dsv://...]` (validation
  rejects `ENC[k8s_secret@...]` / `%%env_...%%`); requires `features.cluster_checks_runner` (only the runners carry the
  cluster-checks identity).
* **Fluent Bit fallback** (fleet node collector `fluent_bit` / `log_pipeline = fluent_bit_direct`): a dsv-fetch `init`
  container writes `/dsv-secrets/fluentbit-env.yaml` into an emptyDir `medium: Memory`; in observability_pipelines
  mode Fluent Bit forwards without a key.
* **OP Worker on AKS** (`op_worker.enabled`): the chart Secret holds only `ENC[...]`; a dsv-fetch `init` container
  writes `/dsv-secrets/opw.env` (dotenv: `DD_API_KEY` + `op_worker.secret_env` DSV references, e.g. the Event Hubs SASL
  password) and the Worker's start command (`/bin/sh`, present in the 2.22.0 image) exports it before
  `observability-pipelines-worker run`. Workload identity `dsv.identity_client_id` on the service account
  `opw-observability-pipelines-worker` (federate it in the caller).

Verified by rendering (`observability/tests/kubernetes/test_datadog_chart.py`: the module's layers from `terraform
console`, `helm template` of datadog 3.253.2, then the post-renderer): init container in all three workloads, backend
env + DSV env + read-only mount in every Agent container, exactly one `DD_API_KEY` (chart Secret) and no duplicate env
entries, service-account annotations, image tags = fleet pin, overrides applied last. Locally (docker) the 2.0.0 binary
installed this way (uid 0, `--cap-drop ALL`, read-only rootfs) runs `agent-backend` inside `datadog/cluster-agent:7.84.2`.
**To verify on a real cluster**: DSV accepting AKS workload-identity tokens (users mapped by `xms_mirid`).

## Other values
* Kubelet TLS (`features.kubelet_tls_mode`): `aks_rotation` (default, `providers.aks.enabled`), `aks_hostca`
  (`spec.nodeName` + `hostCAPath /etc/kubernetes/certs/kubeletserver.crt`), `insecure` (`tlsVerify=false`, last resort).
* Logs: one collector per node - the Agent ships container logs to the OP Worker (`op_logs_url` or the in-cluster
  Worker); the collectors' namespaces are excluded.
* SSI (fleet `apm.mode = datadog`): target namespaces `apm.namespaces`, library majors of the fleet policy, profiler
  `auto`, restricted-PSS securityContext for injected init containers.

Output `contract` = obs-kubernetes v1 (`catalog/contracts/obs-kubernetes.v1.schema.json`).

References:
- https://docs.datadoghq.com/containers/kubernetes/distributions/?tab=helm#AKS
- https://github.com/DataDog/helm-charts/tree/main/charts/datadog ; https://helm.sh/docs/topics/advanced/#post-rendering
- https://docs.datadoghq.com/agent/configuration/secrets-management/
- https://docs.datadoghq.com/containers/cluster_agent/clusterchecks/
- https://learn.microsoft.com/azure/aks/workload-identity-overview
