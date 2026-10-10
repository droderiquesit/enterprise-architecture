# lab/kubernetes (component `obs-kubernetes`)

**Owner:** observability. **Purpose:** Datadog Agent (Helm) + Fluent Bit DaemonSet on the lab AKS cluster through
`modules/kubernetes`.

* **Consumes:**
  * `obs_telemetry_transport` v2 (`datadog_site`, `api_key_ref`, `secrets`)
  * `foundation_identity` v2 (`identities["obs-collector"]`: workload identity of the Agents / Fluent Bit)
  * `artifacts["img-dsv-fetch"]` (dsv-fetch image for the Fluent Bit init container)
  * `platform_aks` (resource_group_name, cluster_id, cluster_name, oidc_issuer_url, access.private_cluster/entra_server_app_id)
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
* The pipeline identities need **Azure Kubernetes Service RBAC Cluster Admin** (+ Cluster User Role) on the
  cluster. platform-aks grants both to every object id in `components.platform-aks.cluster_admin_principals`
  (and the foundation identities in `cluster_admin_identities`, default `deploy-agent`): add the **apply** and
  **plan** pipeline identities' principal ids (bootstrap contract `identities.{apply,plan}.principal_id`).

## API key
No API key input any more (1.x `TF_VAR_datadog_api_key` removed). Default `settings.api_key_mode = dsv_secret_backend`:
the Agents resolve `ENC[<obs_telemetry_transport.api_key_ref>]` with dsv-fetch and Fluent Bit reads it via a dsv-fetch
init container (image = `artifacts["img-dsv-fetch"]`, else the transport contract's `secrets.fetch_image`), both with
AKS workload identity of `obs-collector`. This root federates that identity with `datadog/datadog`,
`datadog/datadog-cluster-checks` and `fluent-bit/fluent-bit` (`azurerm_federated_identity_credential`; the apply
identity needs write access to federated credentials of the identity). Cluster Agent: no Python in its image -
`settings.cluster_agent_secret_name` (dsv-k8s syncer Secret) or degraded (see the module README).
Fallback `api_key_mode = existing`: Secret `synced_secret_name` maintained by the Delinea dsv-k8s syncer.
**To verify on a real cluster**: DSV accepting AKS workload-identity tokens (users are mapped by `xms_mirid`).

## Settings
* `kubelogin_mode`, `kubelet_tls_mode` (aks_rotation)
* `process_collection`, `cluster_checks_runner`
* chart versions, `exclude_namespaces`
* `ssi_namespaces` (default `["hello"]`): Single Step Instrumentation target namespaces when the fleet policy
  `apm.mode` is `datadog`
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
