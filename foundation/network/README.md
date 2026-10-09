# foundation-network

- **Owner:** platform-engineering · **Layer:** foundation · **Component id:** `foundation-network` · **State key:** `<env>/foundation-network.tfstate`
- **Purpose:** the lab network: single-spoke (low cost) or hub-spoke VNets, the ADR §8 subnet catalogue with delegations,
  one NSG per subnet, explicit egress (NAT Gateway or Azure Firewall route), private DNS zones for every Private Link
  service in the catalogue, and a lab-internal DNS zone.
- **Consumes:** nothing. **Produces:** `foundation-network` v1 ([schema](../../catalog/contracts/foundation-network.v1.schema.json)).
- **Status:** implemented (fmt/validate/`terraform test` with mocks). Not deployed.

## Topologies

| `settings.topology` | What is created | Profiles |
|---|---|---|
| `single-spoke` (default) | one VNet `10.41.0.0/16`, NAT Gateway egress, no hub, no peering, no firewall | minimal |
| `hub-spoke` | hub `10.40.0.0/20` + spoke, bidirectional peering (forwarded traffic allowed), zones linked to both | enterprise, full |

`egress = "firewall"` requires `hub-spoke` and `firewall_subnet = true` (validated).

## Address plan (defaults; every prefix overridable via `settings.subnets.<key>.address_prefix`)

| Subnet | Prefix | Delegation | NSG | Explicit egress | Why this size (Microsoft Learn, verified 2026-10-09) |
|---|---|---|---|---|---|
| `aks-nodes` | 10.41.0.0/22 | — | yes | yes | Azure CNI Overlay: only nodes use VNet IPs (1019 nodes) |
| `aca-infra` | 10.41.4.0/23 | `Microsoft.App/environments` | yes | yes | workload-profiles env min **/27** (12 IPs reserved); /23 = 498 IPs ≈ 249 dedicated nodes / ~2490 consumption replicas; cannot be resized later. (ADR §8 says "/23 min" — that is the *consumption-only* minimum; workload profiles need /27. /23 kept for headroom.) |
| `aro-master` | 10.41.6.0/23 | — | no (ARO RP owns NSG) | no (ARO LB) | ARO min /27; PLS network policies disabled (required) |
| `aro-worker` | 10.41.8.0/23 | — | no | no | as above |
| `compute` | 10.41.10.0/24 | — | yes | yes | VMs / VMSS |
| `private-endpoints` | 10.41.11.0/24 | — | yes (PE network policies **Enabled**) | no | one IP per PE |
| `appsvc-integration` | 10.41.12.0/26 | `Microsoft.Web/serverFarms` | yes | yes | App Service/Functions Premium VNet integration (/26 recommended) |
| `flex-integration` | 10.41.12.64/26 | `Microsoft.App/environments` | yes | yes | Flex Consumption: /27 min for one app, /26 recommended for several; delegation **is** `Microsoft.App/environments` (not serverFarms); cannot share with an ACA environment |
| `aci` | 10.41.12.128/26 | `Microsoft.ContainerInstance/containerGroups` | yes | yes | container groups |
| `deploy-agents` | 10.41.12.192/26 | none (VMSS) / `Microsoft.DevOpsInfrastructure/pools` (MDP) | yes | yes | + `Microsoft.Storage` service endpoint for the state-account firewall |
| `postgres` | 10.41.13.0/27 | `Microsoft.DBforPostgreSQL/flexibleServers` | yes | no | Flexible Server VNet injection |
| `mysql` | 10.41.13.32/27 | `Microsoft.DBforMySQL/flexibleServers` | yes | no | Flexible Server VNet injection |
| `sqlmi` | 10.41.13.64/26 | `Microsoft.Sql/managedInstances` | yes + dedicated route table | yes (NAT) | MI min /27; service-aided config adds NSG rules + routes (Terraform ignores them) |
| `cassandra-mi` | 10.41.13.128/26 | — | yes | yes | Managed Instance for Apache Cassandra |
| `observability` | 10.41.13.192/26 | — | yes | yes | collectors, private synthetics, DBM agent |
| `batch` | 10.41.14.0/24 | — | yes | yes | Batch pool nodes |
| `sfmc` | 10.41.15.0/24 | — | yes | yes | Service Fabric managed cluster |
| `apim` (optional, `apim_subnet`) | 10.41.16.0/26 | `Microsoft.Web/serverFarms` | yes (+ KeyVault 443 outbound) | yes | API Management v2 outbound VNet integration (min /27) — **not in ADR §8; amendment requested** |
| `AzureBastionSubnet` (`bastion_subnet`) | hub 10.40.1.0/26 · single-spoke 10.41.17.0/26 | — | yes (Bastion required rules) | no | Basic/Standard Bastion (Developer SKU needs none) |
| `appgw` (`appgw_subnet`) | hub 10.40.2.0/24 · single-spoke 10.41.18.0/24 | — | yes (GatewayManager 65200-65535, listeners) | no | App Gateway v2 |
| `AzureFirewallSubnet` (`firewall_subnet`, hub only) | 10.40.0.0/26 | — | not allowed | — | Azure Firewall |
| `AzureFirewallManagementSubnet` | 10.40.0.64/26 | — | not allowed | — | required by Firewall **Basic** |

Required subnets (contract): `compute`, `private-endpoints`, `aca-infra`, `appsvc-integration`, `deploy-agents`,
`observability` — disabling them fails the plan.

**Plan-time validation** (preconditions on the spoke VNet): every prefix must be a network address, fit its VNet,
not overlap another subnet in the same VNet, hub and spoke spaces must not overlap, required subnets must stay enabled.

## Egress design

- `default_outbound_access_enabled = false` on **every** subnet (private subnets; Azure retires default outbound access).
- `nat-gateway` (default): one Standard NAT Gateway + N static public IPs, associated to subnets marked "explicit egress".
- `firewall`: no NAT Gateway; a `spoke-egress` route table with `0.0.0.0/0 -> VirtualAppliance <firewall IP>` on the same
  subnets (sqlmi keeps its own service-managed route table).

### Switching egress to Azure Firewall

The firewall resource is owned by `foundation-edge`, which consumes this contract, so the switch is two-pass:

1. network: `topology = "hub-spoke"`, `firewall_subnet = true`, keep `egress = "nat-gateway"` → apply.
2. edge: `firewall.enabled = true` → apply (firewall takes the first usable IP `cidrhost(AzureFirewallSubnet, 4)` = `10.40.0.4`).
3. network: `egress = "firewall"` → apply (route table to `10.40.0.4`, NAT Gateway removed). Contract `egress.firewall_private_ip`
   is computed the same way; edge's contract `firewall.private_ip` must match it.

## NSG rules

Every NSG gets `AllowAzureLoadBalancerInbound` (4000) and `DenyInternetInbound` (4096); Azure's default rules still allow
VNet-internal traffic and outbound. Subnet-specific additions: Bastion (all documented required rules), App Gateway v2
(GatewayManager 65200-65535 + listener ports), APIM (VirtualNetwork → AzureKeyVault 443), AKS (`aks_public_ingress` → 80/443).
Rules are standalone `azurerm_network_security_rule` resources and NSGs ignore inline rule drift, so service-managed
rules (SQL MI network intent policy) are never removed by Terraform.

## Private DNS zones (contract `private_dns_zones` short keys)

`blob file queue table dfs sql postgres mysql cosmos_sql cosmos_mongo cosmos_cassandra cosmos_gremlin cosmos_table
mongocluster redis servicebus acr webapps aca aks search kusto batch apim postgres_vnet mysql_vnet` (+ `monitor oms ods
agentsvc` with `ampls_zones = true`, `documentdb` = alias of `mongocluster`, + `private_dns_zones_extra`, − `private_dns_zones_exclude`).

Verified against [Private endpoint DNS zone values](https://learn.microsoft.com/azure/private-link/private-endpoint-dns):
Azure Managed Redis = `privatelink.redis.azure.net`; DocumentDB (Mongo vCore) = `privatelink.mongocluster.cosmos.azure.com`;
ACA = `privatelink.<region>.azurecontainerapps.io`; Data Explorer = `privatelink.<region>.kusto.windows.net`.
**Azure confidential ledger** is not listed as a Private Link resource (checked 2026-10-09) → no zone; platform-db-ledger
must document public endpoint + Entra/cert auth. `postgres_vnet`/`mysql_vnet` are dedicated zones for Flexible Server VNet
injection (`<prefix><env>.private.<engine>.database.azure.com`) so they never clash with private-endpoint records.
Lab internal zone: `<env>.<prefix>.lab.internal` (VM auto-registration on the spoke link).

## Settings (`components.foundation-network`)

| Key | Default | Notes |
|---|---|---|
| `topology` | `single-spoke` | `hub-spoke` |
| `egress` | `nat-gateway` | `firewall` (two-pass, above) |
| `hub_address_space` / `spoke_address_space` | `["10.40.0.0/20"]` / `["10.41.0.0/16"]` | defaults derive subnets with `cidrsubnet` from the first range |
| `subnets.<key>` | `{}` | `address_prefix`, `enabled`, `default_outbound_access_enabled` |
| `bastion_subnet` / `firewall_subnet` / `appgw_subnet` / `apim_subnet` | `false` | edge subnets |
| `deploy_agents_mode` | `vmss` | `managed-devops-pool` delegates `deploy-agents` |
| `nat_gateway` | idle 4 min, no zones, 1 IP | `public_ip_count` 1-16 |
| `private_dns_zones_exclude` / `_extra` / `ampls_zones` | `[]` / `{}` / `false` | |
| `internal_dns_zone`, `internal_dns_zone_registration` | `<env>.<prefix>.lab.internal`, `true` | |
| `aks_public_ingress`, `appgw_listener_ports`, `aro_preconfigured_nsg` | `false`, `[80,443]`, `false` | |

## Cost at defaults

≈ USD 50/month: NAT Gateway ≈ 33 + Standard IP ≈ 4 + ~27 private zones × 0.50 + NAT data processing (0.045/GB).
Hub-spoke adds VNet peering data (≈ 0.01/GB each way). Subnets, NSGs, route tables are free.

## Teardown and data retention

Holds no data. Destroy after every consumer (identity, platform, edge, deploy-agents) — subnets with service association
links (ACA, SQL MI, MDP, delegated Flexible Servers) cannot be deleted while the service still exists; SQL MI subnets can
take hours to release after the instance is deleted. Do not put a Delete lock on the VNet when Managed DevOps Pools are used.

## Known limitations

- SQL MI with `egress = firewall`: MI keeps its service-managed route table; validate MI management connectivity before
  relying on firewall-only egress (default outbound is disabled).
- ARO subnets get no NSG unless `aro_preconfigured_nsg` (ARO "bring your own NSG"); ARO needs outbound via its LB.
- The `apim` subnet key is an addition to the ADR §8 catalogue (requested amendment).
- Bastion/App Gateway subnets live in the hub only for hub-spoke; single-spoke places them in the spoke.

## References

- Container Apps subnet sizing: https://learn.microsoft.com/azure/container-apps/custom-virtual-networks#subnet
- Flex Consumption networking: https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#configure-virtual-network-integration
- Private DNS zone names: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
- Default outbound access: https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access
- Bastion NSG: https://learn.microsoft.com/azure/bastion/bastion-nsg · App Gateway infra: https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure
- ARO networking: https://learn.microsoft.com/azure/openshift/concepts-networking · MDP networking: https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking
- API Management v2 VNet integration: https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
