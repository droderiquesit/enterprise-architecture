# lab/kubernetes-aro (component `obs-kubernetes-aro`)

**Owner:** observability. **Purpose:** Datadog collection on the lab **Azure Red Hat OpenShift** cluster exactly like
AKS (`obs-kubernetes`): node Agent DaemonSet (container logs -> Observability Pipelines Worker, metrics, APM, OTLP,
Single Step Instrumentation, profiler), Cluster Agent (kube-state-metrics core, admission controller) and
cluster-checks runners - through the **same** `modules/kubernetes` with `distribution = "openshift"` (no copy of the
chart wiring). Observability 4.1.0. Status: implemented (static validation, `helm template`); **not deployed or verified
live** (no ARO cluster).

* **Consumes:**
  * `obs_telemetry_transport` (`datadog_site`, `api_key_ref`, `secrets`, `aggregator.agent_logs_url`, `env.fleet`)
  * `foundation_identity` v2 (`identities["obs-collector"]`: node Agent, Cluster Agent, runners)
  * `platform_aro` v1 (`enabled`, `cluster_id`, `cluster_name`, `api_server_url`, `oidc_issuer_url`)
  * `artifacts["img-dsv-fetch"]` (dsv-fetch image >= 2.0.0, digest-pinned: the secret-backend binary)
* **Produces:** `obs-kubernetes-aro` **v1** (`catalog/contracts/obs-kubernetes-aro.v1.schema.json`): the
  obs-kubernetes v2 shape with `distribution = "openshift"`, `enabled`, `status`, `cluster_id`; `{enabled: false,
  status: blocked}` while platform-aro is blocked/disabled (then this root creates nothing).

Why a separate component and not a second release in `obs-kubernetes`: the helm / kubernetes providers are configured
per cluster (AKS: kubelogin exec; ARO: an ephemeral admin kubeconfig), `obs-kubernetes` *requires* `platform-aks`, and
the `specialized` profile has `platform-aro` without `platform-aks`. A separate root keeps each cluster in its own state
and pipeline stage; the Helm wiring stays in one module.

## What is different from AKS (all in `modules/kubernetes`, `distribution = "openshift"`)

| Topic | AKS | OpenShift / ARO | Source |
|---|---|---|---|
| Pod security | PSS labels | chart-created **SecurityContextConstraints**: `datadog` (node Agent: hostPath, host ports, `spc_t`, system-probe seccomp, capabilities; `projected` added for the workload-identity token) and `datadog-cluster-agent` (MustRunAsRange); runners use the default `restricted-v2` | [1], [2], chart `agent-scc.yaml` / `cluster-agent-scc.yaml` |
| Container runtime | containerd (chart default `/var/run`) | **CRI-O** only: `datadog.criSocketPath: /var/run/crio/crio.sock`; logs from `/var/log/pods` | [1], [6] |
| Kubelet TLS | `providers.aks.enabled` (serving-cert rotation) | `datadog.kubelet.tlsVerify: false` (kubelet serving certs are not signed by a CA mounted in the Agent pod) | [1], [2] |
| APM / DogStatsD transport | Unix socket + host port | **host ports only** (8126, 8125); `apm.socketEnabled: false`, `dogstatsd.useSocketVolume: false` - sockets need a hostPath volume (privileged) in every application pod | [1], [3] |
| Admission controller (SSI, config injection) | socket mode | `clusterAgent.admissionController.configMode: hostip` ("If you are using OpenShift, use hostip mode") | [3] |
| Host network | no | no (`agents.useHostNetwork` is optional on OpenShift - only for cloud metadata; set it through `values_overrides` if needed) | [1] |
| Node placement | all Linux nodes | `nodeSelector node-role.kubernetes.io/worker: ""` - ARO support policy: no extra workloads on control plane or infrastructure nodes | [6], [7] |
| `dsv-fetch-install` init container | uid 0 in all three workloads | uid 0 in the DaemonSet (SCC `datadog`, RunAsAny, the Agent runs as root); **no fixed UID** in the Cluster Agent / runner Deployments (MustRunAsRange: the SCC assigns one UID to every container, so the 0500 binary is owned by the Agent process user) - post-renderer `--distribution openshift` | chart SCCs, `postrender/dsv-fetch-init.sh` |
| Fluent Bit fallback, in-cluster OP Worker | supported | rejected (plan error): the node Agent is the only log collector; the Container Apps Worker (`op_logs_url`) receives the logs | - |
| OpenShift control-plane checks | n/a | `providers.openshift.controlPlaneMonitoring` stays off (needs the etcd client certificate copied into the Agent namespace) | chart `values.yaml` |
| SSI | supported | configured identically (targets = `settings.ssi_namespaces`, restricted securityContext for injected init containers - compatible with `restricted-v2`); Datadog's SSI compatibility page lists Kubernetes generally, not OpenShift explicitly: **to verify** | [4], [5] |

Pinned chart: `datadog` **3.253.2** (`versions.yaml`/module default); the keys above exist in that chart version
(checked in its `values.yaml` and templates). OpenShift's global Pod Security Admission enforce level is `privileged`
(label sync sets only `warn` / `audit`), so the `datadog` namespace needs no PSA labels [8].

## API key: one secret path (Delinea DSV, ADR-0001 section 14)
No API key input, no Kubernetes Secret with the key, no Key Vault, nothing secret in state: the node Agent, the Cluster
Agent and the runners resolve `ENC[<api_key_ref>]` with the static dsv-fetch binary (`secret_backend_command`,
`agent-backend`), authenticating to DSV with **Microsoft Entra workload identity**.

**Does ARO support workload identity? Yes - managed-identity clusters.** ARO clusters created with managed identities
(the model `platform-aro` uses: cluster identity + platform workload identities) have a **managed OIDC issuer**
(`clusterProfile.oidcIssuer`, `https://<region>.oic.aro.azure.net/<tenant>/<uuid>`) and run the pod-identity mutating
webhook (`openshift-cloud-credential-operator`): a service account annotated `azure.workload.identity/client-id` and a pod
labelled `azure.workload.identity/use: "true"` get `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`
and the projected token - the same contract as AKS, which dsv-fetch already implements [9], [10]. azurerm 5.9 does not
expose the issuer, so `platform-aro` reads it (GET) with azapi `Microsoft.RedHatOpenShift/openShiftClusters@2025-07-25`
and publishes `oidc_issuer_url` [11]. This root federates `obs-collector` with `datadog/datadog`,
`datadog/datadog-cluster-agent` and (runners on) `datadog/datadog-cluster-checks` (`azurerm_federated_identity_credential`,
audience `api://AzureADTokenExchange`). A cluster without an issuer fails the plan (precondition).

Alternatives considered (not implemented): a service-principal ARO cluster has no OIDC issuer - an Entra app with a
client secret, or DSV client credentials stored in a Kubernetes Secret, would put a long-lived credential in the
cluster (and in state, if Terraform wrote it), which ADR-0001 section 14 forbids; Key Vault + CSI driver is excluded by
the same section. Managed-identity clusters make all of them unnecessary.

## Provider authentication (helm / kubernetes)
ARO standard clusters have no Entra / kubelogin path to the Kubernetes API (OpenShift OAuth is interactive), so
`settings.kube_auth`:

* **`admin_kubeconfig`** (default): `ephemeral "azapi_resource_action"` `listAdminCredentials` (the ARM action behind
  `az aro get-admin-kubeconfig`) [12], decoded in the provider configuration only. Ephemeral values are **never stored
  in the plan or the state** (Terraform >= 1.10). Trade-offs: the credential is the `system:admin` client certificate
  (cluster-admin, long-lived, not revocable per run) and is present in the deploy agent's memory during the run; the
  plan **and** apply identities need `Microsoft.RedHatOpenShift/openShiftClusters/listAdminCredentials/action` on the
  cluster (built-in *Contributor* has it). Private API server (default): self-hosted deploy agents in the VNet. CA from
  the kubeconfig's `certificate-authority-data`, else `settings.api_ca_certificate` (PEM, not secret), else the agent's
  trust store - never `insecure-skip-tls-verify`.
* **`kubeconfig`**: `settings.kubeconfig_path` - a kubeconfig the pipeline prepares before Terraform (e.g. `oc login
  --token` of a least-privilege deployer service account whose token is kept in DSV and fetched with
  `tools/secrets/fetch.py`). Less privilege than cluster-admin, but a long-lived token exists (in DSV) and must be
  rotated; bootstrap of that service account needs the admin path once. Also used by the tests (mock providers cannot
  open ephemeral resources).

## Settings
* `collector_identity_key` (`obs-collector`), `process_collection`, `cluster_checks_runner` (true), `datadog_chart_version`
* `exclude_namespaces` (kube_namespace regexes, default `datadog`, `kube-system`, `^openshift-`)
* `ssi_namespaces` (default `["hello"]`, fleet `apm.mode = datadog`)
* `kube_auth` / `kubeconfig_path` / `api_ca_certificate` (above), `values_overrides` (last layer; the secret path cannot
  be overridden)
* Log pipeline: the transport's `env.fleet` switches; without them `observability_pipelines` (needs
  `aggregator.agent_logs_url`). `fluent_bit_direct` fails the plan on OpenShift.
* DBM cluster checks: not wired here (obs-dbm keeps its own hosting).

## Cost
In-cluster only (worker node capacity): agent about 0.3 vCPU / 0.5 GiB per worker, Cluster Agent + runner about
0.2 vCPU / 0.4 GiB. Nothing when platform-aro is disabled.

## Teardown
Destroy uninstalls the Helm release (and with it the chart SCCs), deletes the namespace and the federated credentials.

## To verify on a real cluster (not possible here)
SCC admission of the three workloads (Agent image as an SCC-assigned non-root UID for Cluster Agent / runners), token
injection by the OpenShift pod-identity webhook and DSV accepting it, CRI-O check + `/var/log/pods` tailing under
`spc_t`, SSI injection into `restricted-v2` application pods, the admin kubeconfig's CA. See
[docs/known-limitations.md](../../../docs/known-limitations.md).

## References
1. Datadog, Kubernetes distributions - OpenShift: https://docs.datadoghq.com/containers/kubernetes/distributions/?tab=helm#Openshift
2. Datadog Helm chart example `agent_on_openshift_values.yaml`: https://github.com/DataDog/helm-charts/blob/main/examples/datadog/agent_on_openshift_values.yaml
3. Datadog, Admission Controller troubleshooting (OpenShift: hostip mode): https://docs.datadoghq.com/containers/troubleshooting/admission-controller/?tab=helm
4. Datadog, SSI compatibility: https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/compatibility/
5. Datadog, SSI troubleshooting (init container security context): https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/troubleshooting
6. Microsoft Learn, ARO service definition (CRI-O only, DaemonSet node selector): https://learn.microsoft.com/azure/openshift/openshift-service-definitions
7. Microsoft Learn, ARO support policy (no extra workloads on control plane / infrastructure nodes): https://learn.microsoft.com/azure/openshift/support-policies-v4
8. Red Hat, Understanding and managing pod security admission (OpenShift 4.18): https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/understanding-and-managing-pod-security-admission
9. Microsoft Learn, Deploy and configure an application using workload identity on an ARO managed identity cluster: https://learn.microsoft.com/azure/openshift/howto-deploy-configure-application
10. Microsoft Learn, Understand managed identities in ARO: https://learn.microsoft.com/azure/openshift/howto-understand-managed-identities
11. Microsoft Learn, `Microsoft.RedHatOpenShift/openShiftClusters` API change log (`clusterProfile.oidcIssuer`): https://learn.microsoft.com/azure/templates/microsoft.redhatopenshift/change-log/openshiftclusters
12. Microsoft Learn, Use Admin Kubeconfig to access an ARO cluster: https://learn.microsoft.com/azure/openshift/howto-kubeconfig

## Test
`terraform init -backend=false && terraform test` in this directory (mock azurerm / helm / kubernetes; azapi unmocked
and unused in the tests): `tests/lab.tftest.hcl`. Chart render of the OpenShift layer:
`observability/tests/kubernetes/test_datadog_chart.py`. From the repository root:
`python3 tools/validate/all_terraform.py --only obs-kubernetes-aro`.
