# platform/compute/servicefabric — Service Fabric managed cluster

| | |
|---|---|
| Component id | `platform-servicefabric` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.sfmc`, optional BYO VNet), `foundation-identity` v2 (`identities["obs-host-agent"]`, the Datadog DSV reader) |
| Produces | `platform-servicefabric` v1 (1.1.0: `node_types`, `datadog`; `status = disabled` unless enabled) |
| Status | **`disabled`** by default (cost); `implemented` when `enabled = true` (not deployed / verified live) |

## What it creates (when `enabled = true`)

- Service Fabric **managed cluster**, SKU **Basic** (Learn: Basic = minimum **3** nodes, one node type, no
  zone redundancy; Standard = minimum 5) with one primary Windows node type `nt1`: 3 × `Standard_D2s_v5`,
  `WindowsServer/2022-datacenter-azure-edition`, 128 GB StandardSSD data disk.
- Ports: client 19000, HTTP gateway 19080, LB rule `8080/tcp` with HTTP probe `/healthz` for the
  hello-inventory-api guest executable (deployed by `deploy-specialized`).
- Authentication: client certificate thumbprint (`client_certificate_thumbprint`, admin client) and/or Entra
  ID (`entra_cluster_application_id` + `entra_client_application_id`) — **required when enabled** (validated).
- Node RDP admin password: `random_password` (state only); it reaches the cluster through the azapi write-only
  `sensitive_body`, so the cluster resource's state does not hold it.
- BYO VNet: set `sf_resource_provider_principal_id` (object id of the tenant's *Azure Service Fabric Resource
  Provider* service principal) → *Network Contributor* on `sfmc` and the cluster joins that subnet; `byo_vnet = false`
  keeps the managed VNet although the principal id is set (needed for the Datadog identity below).
- **Datadog Agent on the nodes** (`settings.datadog`, default on; observability 4.1.0): the node type gets the
  per-environment DSV-reader identity `obs-host-agent` in `vmManagedIdentity`, the SF resource provider gets
  *Managed Identity Operator* on that identity (so `sf_resource_provider_principal_id` is required), the node type is
  tagged `datadog:enabled = "true"` (+ `node_type.tags`, e.g. `service`), and the contract lists the node type
  (`node_types.nt1 = {id, os_type = windows, datadog_enabled}`). `obs-hosts` then sets the node type's
  `vmApplications` to the pinned `datadog-agent-windows` VM Application version. This root **never sends
  `properties.vmApplications`** (`ignore_body_changes`), so its applies keep the Agent.

## Why azapi, not `azurerm_service_fabric_managed_cluster` (provider gap)

Research (2026-10-10), recorded in `catalog/provider-gaps.yaml` (`service-fabric-managed`):

- Node types of a managed cluster are VMSS in a Microsoft-managed resource group (`SFC_<cluster id>`). A deny assignment
  blocks VMSS delete / reimage / restart / deallocate and load-balancer / storage writes there, and "all actions related
  to managed clusters should be done through the managed cluster resource APIs instead of directly against the
  infrastructure resource group" ([deny assignment](https://learn.microsoft.com/azure/service-fabric/managed-cluster-deny-assignment));
  "manually making changes to the resources in a managed cluster isn't supported"
  ([configuration options](https://learn.microsoft.com/azure/service-fabric/how-to-managed-cluster-configuration)).
  VMSS *write* is not on the deny list, but the resource provider owns the VMSS model, so an Azure Policy
  DeployIfNotExists patch of the node VMSS (the `obs-hosts` path for VMs / VMSS) is unsupported and would be reverted
  or fought on the next node type operation. The node type API is the supported path.
- The node type API (`Microsoft.ServiceFabric/managedClusters/nodeTypes`, latest GA **2026-02-01**; 2026-05-01-preview
  exists) supports `vmApplications[] {packageReferenceId, order, configurationReference, treatFailureAsDeploymentFailure,
  enableAutomaticUpgrade, vmGalleryTags}` ("gallery applications that should be made available to the underlying VMSS"),
  `vmManagedIdentity.userAssignedIdentities`, `vmExtensions`, `vmImage*` / `vmImageResourceId` /
  `vmSharedGalleryImageId`, `additionalDataDisks`, `vmSecrets`, `vmSetupActions` and resource `tags`
  ([ARM reference 2026-02-01](https://learn.microsoft.com/azure/templates/microsoft.servicefabric/2026-02-01/managedclusters/nodetypes)).
  User-assigned identities only, and the SF resource provider needs *Managed Identity Operator* on the identity
  ([managed identity on a node type](https://learn.microsoft.com/azure/service-fabric/how-to-managed-identity-managed-cluster-virtual-machine-scale-sets)).
- azurerm 5.9.0 `node_type` exposes only `application_port_range, capacities, data_disk_size_gb, data_disk_type,
  ephemeral_port_range, multiple_placement_groups_enabled, name, placement_properties, primary, stateless,
  vm_image_{publisher,offer,sku,version}, vm_instance_count, vm_secrets, vm_size` (`terraform providers schema -json`),
  and its Update PUTs every configured node type from those fields only (go-azure-sdk `2024-04-01`, no GET/merge), so
  a node type identity or VM Application set by anyone else would be dropped (= Agent uninstalled) on any cluster
  change. Both resources are therefore `azapi_resource` (2026-02-01, embedded in azapi 2.13.0).
- Datadog documents the Agent on Service Fabric as the `DatadogWindowsAgent` / `DatadogLinuxAgent` VMSS extension with
  the API key in protected settings ([Datadog: Azure Service Fabric](https://docs.datadoghq.com/integrations/azure-service-fabric)).
  Not used: it targets the node VMSS directly (unsupported on managed clusters) and the key would pass through ARM /
  Terraform. The node type's `vmApplications` delivers the same non-secret installer as every other host instead, and
  the Agent resolves `api_key: ENC[dsv://...]` with the `dsv-fetch` secret backend
  ([Datadog secrets management](https://docs.datadoghq.com/agent/configuration/secrets-management/)).
  VM extensions (`vmExtensions`, e.g. CustomScript) would also be possible, but VM Applications are supported on the
  node type, so the fleet keeps one install path.

## Migration from an earlier version of this root

Earlier versions used `azurerm_service_fabric_managed_cluster`. A cluster created that way must be moved to the azapi
resources before the next apply, otherwise the plan destroys and recreates it:

```bash
terraform state rm 'azurerm_service_fabric_managed_cluster.this[0]'
# then, for one plan/apply, import blocks in this root:
#   import { to = azapi_resource.cluster[0]   id = "<cluster id>?api-version=2026-02-01" }
#   import { to = azapi_resource.node_type[0] id = "<cluster id>/nodeTypes/nt1?api-version=2026-02-01" }
```

The node type update that adds the identity is a rolling (per upgrade domain) node type upgrade.

## Known limitations

- The managed cluster exposes a public IP for 19000/19080 (certificate/Entra-protected); the NSG rules are not modelled
  (`networkSecurityRules` could be added to the azapi body; today `az sf managed-cluster network-security-rule`).
- Certificates are not created here (bring the client certificate thumbprint; the certificate itself is managed out
  of band, PFX kept in Delinea DSV if needed).
- Whether node type `tags` reach the node VMSS (IMDS `tagsList`, read by the Agent installer for `service` /
  `datadog:log_paths`) is not documented; without them the nodes use the default service `platform` and the default
  Windows host-log paths (`C:\ProgramData\enterprise-hello\logs\*.log`, where `deploy-specialized` writes the app log).
- `tools/validate/plan_policy.py` classifies azurerm types only; deleting the azapi cluster is not flagged as a protected
  destroy.
- Nothing here was deployed or verified against Azure (mock-provider tests and azapi embedded-schema validation only).

## Cost when enabled (approx.)

3 × D2s_v5 Windows ≈ USD 410/month + Standard LB/public IP ~20 + disks ~30. Disabled: 0. Datadog bills the 3 Agent hosts.

## Validation

```bash
python3 tools/validate/all_terraform.py --only platform-servicefabric   # fmt, init -backend=false, validate, terraform test (mock providers)
```

## Docs

- https://learn.microsoft.com/azure/service-fabric/overview-managed-cluster
- https://learn.microsoft.com/azure/service-fabric/how-to-managed-cluster-vnet
- https://learn.microsoft.com/azure/service-fabric/how-to-managed-cluster-azure-active-directory-client
- https://learn.microsoft.com/azure/service-fabric/how-to-managed-identity-managed-cluster-virtual-machine-scale-sets
- https://learn.microsoft.com/azure/service-fabric/managed-cluster-deny-assignment
- https://learn.microsoft.com/azure/templates/microsoft.servicefabric/2026-02-01/managedclusters/nodetypes
