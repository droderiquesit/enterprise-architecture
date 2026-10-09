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

## API key, never in state
* `api_key.mode = write_only` (default): a Secret `datadog-api-key` (key `api-key`) is created in both
  namespaces from the **ephemeral** input `api_key_wo` through `kubernetes_secret_v1.data_wo`. Bump `revision`
  to rotate.
* `existing`: the caller syncs the Secret, for example with the Secrets Store CSI driver + Azure Key Vault
  provider `secretObjects`, or with External Secrets.

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
- https://learn.microsoft.com/azure/aks/csi-secrets-store-driver (alternative `existing` mode)
