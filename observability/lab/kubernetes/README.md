# lab/kubernetes (component `obs-kubernetes`)

**Owner:** observability. **Purpose:** Datadog Agent (Helm) + Fluent Bit DaemonSet on the lab AKS cluster through
`modules/kubernetes`.

* **Consumes:**
  * `obs_telemetry_transport.datadog_site`
  * `platform_aks` (resource_group_name, cluster_id, cluster_name, access.private_cluster/entra_server_app_id)
* **Produces:** `obs-kubernetes` v1 (`catalog/contracts/obs-kubernetes.v1.schema.json`): the agent local
  service, OTLP ports, `DD_AGENT_HOST` convention, cluster-agent service, Fluent Bit namespace and exclusions,
  `log_route = daemonset`, `cluster_id`.

## Provider configuration
* `data.azurerm_kubernetes_cluster` supplies the host and CA. Local accounts are disabled.
* The `helm` and `kubernetes` providers use the **kubelogin exec plugin**:
  `kubelogin get-token --login <azurecli|workloadidentity|msi> --server-id 6dae42f8-4368-4678-94ff-3960e28e3630`
  (the AKS Entra server application).
* The pipeline runs it after `azure/login` with OIDC (`azurecli`). A private cluster needs the self-hosted deploy
  agents in the VNet.
* The pipeline identity needs **Azure Kubernetes Service RBAC Cluster Admin** (or a namespace-scoped writer
  role) on the cluster: platform-aks request.

## API key
`TF_VAR_datadog_api_key` is an **ephemeral** variable. The pipeline exports it from Key Vault in the same step
that sets `DD_API_KEY` for the Datadog provider. It is written with `kubernetes_secret_v1.data_wo` and never
stored.

## Settings
* `kubelogin_mode`, `kubelet_tls_mode` (aks_rotation)
* `process_collection`, `cluster_checks_runner`
* chart versions, `exclude_namespaces`
* `dbm_cluster_checks` (from obs-dbm `cluster_check_confd` when obs-dbm hosting = cluster_checks)

## Cost
In-cluster only (node capacity). Requests: agent about 0.3 vCPU / 0.5 GiB per node, Fluent Bit 0.1 vCPU /
128 MiB per node, cluster agent + runner about 0.2 vCPU / 0.4 GiB.

## Teardown
Destroy uninstalls both Helm releases, deletes the Secrets and ConfigMap, and deletes the namespaces it
created. The tail position database on the node hostPath (`/var/fluent-bit/state`) stays until the node is
recycled.

## Limitations
The Fluent Bit kubernetes filter is not exercised locally because it needs an API server; only the dry-run is
done.
