# modules/kubernetes

Installs the Datadog Agent (Helm chart `datadog` **3.253.2**, Agent and Cluster Agent **7.84.2**) and the Fluent
Bit DaemonSet (chart `fluent-bit` **0.58.3**, image `fluent/fluent-bit:5.1.3`) on an **existing** cluster.
Chart versions were taken from the chart indexes on 2026-10-09 (`https://helm.datadoghq.com/index.yaml`:
datadog 3.253.2, datadog-operator 2.28.0; `https://fluent.github.io/helm-charts/index.yaml`: fluent-bit 0.58.3
with app version 5.1.3).

Only `helm` and `kubernetes` resources are used. **The caller configures the providers** (host, CA, kubelogin
exec plugin; the repository's lab Kubernetes root is one example).

## Datadog values (rendered locally with `helm template` against the real chart)
* `datadog.logs.enabled=false`, `containerCollectAll=false`. Fluent Bit owns container logs.
* OTLP gRPC on 4317 and HTTP on 4318 with `useHostPort: true`. Apps use `http://$(DD_AGENT_HOST):4317`.
  OTLP logs are off.
* APM (socket + hostPort 8126). Process collection is optional. The Cluster Agent is on. Cluster checks are on
  and `clusterChecksRunner` runs DBM checks (`cluster_checks` input from `modules/dbm`).
* AKS kubelet TLS (`features.kubelet_tls_mode`):
  * `aks_rotation` (default): `providers.aks.enabled=true`, for current AKS with kubelet serving-certificate
    rotation.
  * `aks_hostca`: kubelet host from `spec.nodeName` plus `hostCAPath /etc/kubernetes/certs/kubeletserver.crt`.
  * `insecure`: `datadog.kubelet.tlsVerify=false`. This is Datadog's documented last resort for AKS, and it is
    never combined with hostCAPath.
* The chart's bundled Datadog Operator sub-chart and system-probe discovery are switched off
  (`features.operator_subchart`, `service_discovery`). This was verified by rendering: a DaemonSet with the
  agent and trace-agent, plus the cluster-agent and clusterchecks Deployments.
* All containers have bounded requests and limits.

## API key: Delinea DSV, never in Terraform
* `api_key.mode = dsv_secret_backend` (default): the chart Secret holds only the reference
  `ENC[<dsv.api_key_ref>]`. Agents (all DaemonSet containers) and cluster-checks runners run
  `secret_backend_command = /opt/dsv-fetch/dsv-fetch` with `agent-backend` - the stdlib `images/dsv-fetch/dsv_fetch.py`
  from a ConfigMap mounted with `defaultMode 0500` (root-owned, no group/other rights, interpreter = the Agent image's
  `python3`; the chart has no hook for extra init containers, so the `dsv-fetch install` init-container variant is not
  used). Authentication: AKS workload identity (`azure.workload.identity/use` pod label via `additionalLabels`,
  client-id annotation on the service accounts `datadog` and `datadog-cluster-checks` - the runners get a dedicated
  service account). `DSV_*` env on both. DB passwords in cluster checks use the same `ENC[dsv://...]` handles.
  Fluent Bit: a dsv-fetch init container (`dsv.fetch_image`, non-root, read-only rootfs) writes
  `/dsv-secrets/fluentbit-env.yaml` into an emptyDir `medium: Memory` (1 Mi) that `k8s-daemonset.yaml` includes; no
  `DD_API_KEY` env. Verified by `helm template` of datadog 3.253.2 (env order, labels, service accounts, mounts).
* **Cluster Agent**: its image has no Python interpreter, so dsv-fetch cannot run there. With
  `api_key.cluster_agent_secret_name` the DCA's `DD_API_KEY` comes from that Secret (maintained by the Delinea dsv-k8s
  syncer; the entry follows the chart's own `DD_API_KEY`, and the later duplicate wins); without it the DCA's secret
  backend is disabled and features that need a valid key (orchestrator explorer, DCA telemetry) cannot authenticate -
  cluster-check dispatch still works.
* **To verify**: that DSV accepts tokens obtained through AKS workload-identity federation (DSV maps users by the
  identity's resource id, `xms_mirid`).
* `existing` (documented fallback): Secret `<secret_name>` (key `api-key`) in both namespaces, maintained by the
  Delinea DSV Kubernetes syncer (dsv-k8s); Fluent Bit takes `DD_API_KEY` from it and includes an empty placeholder
  env file.

## Fluent Bit
* The ConfigMap `fluent-bit-obs-config` holds `fluent-bit.yaml`, `parsers.yaml` and `enterprise_hello.lua`. It
  is mounted with items at `/fluent-bit/etc/eh`. Args are `--config=/fluent-bit/etc/eh/fluent-bit.yaml`, so
  the chart's default classic config is unused.
* State lives on a hostPath at `/var/fluent-bit/state` (tail DB plus the filesystem buffer).
* The pod annotation `checksum/obs-config` rolls the pods when the config changes.
* Self-metrics are pushed over OTLP to the node Agent (`DD_AGENT_HOST` comes from `status.hostIP`), and the
  names keep `_total`.

Output `contract` = obs-kubernetes v1 (`catalog/contracts/obs-kubernetes.v1.schema.json`).

References:
- https://docs.datadoghq.com/containers/kubernetes/distributions/?tab=helm#AKS
- https://docs.datadoghq.com/containers/kubernetes/installation/?tab=helm ; https://github.com/DataDog/helm-charts/tree/main/charts/datadog
- https://docs.datadoghq.com/opentelemetry/setup/otlp_ingest_in_the_agent/?tab=kubernetesdaemonset
- https://docs.datadoghq.com/containers/cluster_agent/clusterchecks/
- https://github.com/fluent/helm-charts/tree/main/charts/fluent-bit ; https://docs.fluentbit.io/manual/pipeline/filters/kubernetes
- https://docs.datadoghq.com/agent/configuration/secrets-management/ ; https://learn.microsoft.com/azure/aks/workload-identity-overview
