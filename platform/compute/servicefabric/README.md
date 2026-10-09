# platform/compute/servicefabric — Service Fabric managed cluster

| | |
|---|---|
| Component id | `platform-servicefabric` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.sfmc`, optional BYO VNet) |
| Produces | `platform-servicefabric` v1 (`status = disabled` unless enabled) |
| Status | **`disabled`** by default (cost); `implemented` when `enabled = true` |

## What it creates (when `enabled = true`)

- Service Fabric **managed cluster**, SKU **Basic** (Learn: Basic = minimum **3** nodes, one node type, no
  zone redundancy; Standard = minimum 5) with one primary Windows node type `nt1`: 3 × `Standard_D2s_v5`,
  `WindowsServer/2022-datacenter-azure-edition`, 128 GB StandardSSD data disk.
- Ports: client 19000, HTTP gateway 19080, LB rule `8080/tcp` with HTTP probe `/healthz` for the
  hello-inventory-api guest executable (deployed by `deploy-specialized`).
- Authentication: client certificate thumbprint (`client_certificate_thumbprint`, type AdminClient) and/or Entra
  ID (`entra_cluster_application_id` + `entra_client_application_id`) — **required when enabled** (validated).
- Node RDP admin password: `random_password`, state only.
- BYO VNet: set `sf_resource_provider_principal_id` (object id of the tenant's *Service Fabric Resource
  Provider* service principal) → *Network Contributor* on `sfmc` and the cluster joins that subnet; otherwise
  the managed cluster creates its own VNet.

## Known limitations

- The managed cluster exposes a public IP for 19000/19080 (certificate/Entra-protected); azurerm does not
  expose managed-cluster NSG rules, so restricting sources needs `az sf managed-cluster network-security-rule`.
- Certificates are not created here (bring the client certificate thumbprint; the certificate itself is managed out of band, PFX kept in Delinea DSV if needed).

## Cost when enabled (approx.)

3 × D2s_v5 Windows ≈ USD 410/month + Standard LB/public IP ~20 + disks ~30. Disabled: 0.

## Docs

- https://learn.microsoft.com/azure/service-fabric/overview-managed-cluster
- https://learn.microsoft.com/azure/service-fabric/how-to-managed-cluster-vnet
- https://learn.microsoft.com/azure/service-fabric/how-to-managed-cluster-azure-active-directory-client
