# platform/compute/servicefabric — Service Fabric managed cluster

| | |
|---|---|
| Component id | `platform-servicefabric` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.sfmc`, optional BYO VNet), `foundation-identity` v2 (`identities["obs-host-agent"]`, the Datadog DSV reader) |
| Produces | `platform-servicefabric` v1 (1.1.0: `node_types`, `datadog`; `status = disabled` unless enabled) |
| Status | **`disabled`** by default (cost); `implemented` when `enabled = true` (not deployed / verified live) |

## What it creates (when `enabled = true`)

- Service Fabric **managed cluster**, SKU **Basic** (minimum **3** nodes, one node type, no zone redundancy) with one primary Windows node type `nt1`: 3 × `Standard_D2s_v5`,
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
- **Datadog Agent on the nodes** (`settings.datadog`, default on): the node type gets the
  per-environment DSV-reader identity `obs-host-agent` in `vmManagedIdentity`, the SF resource provider gets
  *Managed Identity Operator* on that identity (so `sf_resource_provider_principal_id` is required), the node type is
  tagged `datadog:enabled = "true"` (+ `node_type.tags`, e.g. `service`), and the contract lists the node type
  (`node_types.nt1 = {id, os_type = windows, datadog_enabled}`). `obs-hosts` then sets the node type's
  `vmApplications` to the pinned `datadog-agent-windows` VM Application version. This root **never sends
  `properties.vmApplications`** (`ignore_body_changes`), so its applies keep the Agent.

## Why azapi, not `azurerm_service_fabric_managed_cluster` (provider gap)

Node types are VMSS in the Microsoft-managed `SFC_` resource group and may only be changed through the node type API, so
neither Azure Policy nor the Datadog VMSS extension can enrol them. azurerm 5.9 models no node type identity or
`vmApplications` and its update re-PUTs node types without them (= Agent uninstalled), so cluster and node type are
`azapi_resource` (2026-02-01). Details and references: `catalog/provider-gaps.yaml` (`service-fabric-managed`).

## Migration from an earlier version of this root

A cluster created with `azurerm_service_fabric_managed_cluster` must be moved to the azapi resources before the next
apply, otherwise the plan recreates it:

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
