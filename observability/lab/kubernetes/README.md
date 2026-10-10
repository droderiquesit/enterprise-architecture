# lab/kubernetes (component `obs-kubernetes`)

**Owner:** observability. **Purpose:** Datadog Agent (Helm) + Fluent Bit DaemonSet on the lab AKS cluster through
`modules/kubernetes`.

* **Consumes:**
  * `obs_telemetry_transport` v2 (`datadog_site`, `api_key_ref`, `secrets`)
  * `foundation_identity` v2 (`identities["obs-collector"]`: Agents / Cluster Agent / Fluent Bit;
    `identities["obs-dbm"]`: cluster-checks runners when DBM runs here; `secrets.base_path`)
  * `artifacts["img-dsv-fetch"]` (dsv-fetch image >= 2.0.0: secret-backend binary of all Agents, Fluent Bit init)
  * optional `platform_db_*` contracts (`dbm` blocks) -> DBM cluster checks
  * `platform_aks` (resource_group_name, cluster_id, cluster_name, oidc_issuer_url, access.private_cluster/entra_server_app_id)
* **Produces:** `obs-kubernetes` **v2** (`catalog/contracts/obs-kubernetes.v2.schema.json`; v1 kept for rollback): the agent local
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
No API key input. The node Agents, the Cluster Agent and the cluster-checks runners resolve
`ENC[<obs_telemetry_transport.api_key_ref>]` with the static dsv-fetch binary (secret backend, copied by the init
container `dsv-fetch-install` from `artifacts["img-dsv-fetch"]`, else the transport contract's `secrets.fetch_image`);
the Fluent Bit fallback reads it through a dsv-fetch init container. All with AKS workload identity: this root
federates `obs-collector` with `datadog/datadog`, `datadog/datadog-cluster-agent`, `fluent-bit/fluent-bit` and - when
no DBM checks run here - `datadog/datadog-cluster-checks` (`azurerm_federated_identity_credential`; the apply identity
needs `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write` on the identities - included
in bootstrap's subscription-scope Contributor of the apply identity; a narrower setup grants *Managed Identity
Contributor* on the foundation-identity resource group). With DBM checks on the cluster the `obs-dbm` identity is
federated with `datadog/datadog-cluster-checks` instead (the runners read the `dbm-*-password` paths; foundation
`secrets.yaml` lists obs-kubernetes in their `required_by`). There is no synced-Secret / existing-Secret mode any
more (observability 4.0.0). **To verify on a real cluster**: DSV accepting AKS workload-identity tokens (`xms_mirid`).

## DBM (settings.dbm = auto)
The optional platform-db contracts are rendered by `modules/dbm/contracts` + `modules/dbm` (`hosting =
cluster_checks`) into `clusterAgent.confd`: the Cluster Agent dispatches them to the cluster-checks runners, which run
as the `obs-dbm` identity (federated here with `datadog/datadog-cluster-checks`): DSV read on the DB password paths
(`ENC[dsv://...]`) and the Entra database login. obs-dbm (`settings.hosting = auto`) sees the same platform-aks contract
and creates no ACI Agent. `settings.dbm = off` leaves DBM to obs-dbm (`hosting = aci`).

## Settings
* `kubelogin_mode`, `kubelet_tls_mode` (aks_rotation)
* `process_collection`, `cluster_checks_runner` (required for DBM)
* chart versions, `exclude_namespaces`
* `ssi_namespaces` (default `["hello"]`): Single Step Instrumentation target namespaces when the fleet policy
  `apm.mode` is `datadog`
* `dbm` (`auto` | `off`), `dbm_identity_key` (`obs-dbm`), `collector_identity_key` (`obs-collector`)
* `values_overrides`: per-cluster Datadog chart values (YAML documents), the last values layer (the module rejects
  changes to the secret path)

## Cost
In-cluster only (node capacity). Requests: agent about 0.3 vCPU / 0.5 GiB per node, Fluent Bit 0.1 vCPU /
128 MiB per node, cluster agent + runner about 0.2 vCPU / 0.4 GiB.

## Teardown
Destroy uninstalls the Helm releases, deletes the ConfigMap, the federated credentials and the namespaces it
created. The tail position database on the node hostPath (`/var/fluent-bit/state`) stays until the node is
recycled.

## Limitations
The Fluent Bit kubernetes filter is not exercised locally because it needs an API server; only the dry-run is
done.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/lab.tftest.hcl`. From the repository root: `python3 tools/validate/all_terraform.py --only obs-kubernetes` (fmt, validate, test).
