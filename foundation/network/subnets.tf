# Subnet catalogue (ADR-0001 §8). Names are fixed; prefixes are configurable via settings.subnets.
#
# Sizing rationale (verified on Microsoft Learn 2026-10-09):
#   aks-nodes          /22  Azure CNI Overlay: only nodes take VNet IPs (pods use the overlay CIDR); 1019 nodes max.
#   aca-infra          /23  Workload-profiles environments need >= /27 (12 IPs reserved); /23 = 498 usable IPs
#                           (249 dedicated nodes or ~2490 consumption replicas). Subnet can't be resized after creation.
#   aro-master/worker  /23  ARO docs minimum /27, examples and Red Hat guidance use /23 each.
#   appsvc-integration /26  App Service/Functions Premium VNet integration: /26 recommended for scale + upgrades.
#   flex-integration   /26  Flex Consumption: /27 minimum for one app, /26 recommended for several apps.
#   aci                /26  delegated container groups, one IP per group.
#   deploy-agents      /26  VMSS / Managed DevOps Pools (max pool size + 5 reserved).
#   postgres, mysql    /27  Flexible Server VNet injection (dedicated delegated subnets).
#   sqlmi              /26  SQL MI minimum /27; /26 leaves room for a second instance / updates.
#   cassandra-mi       /26  Managed Instance for Apache Cassandra datacenter nodes.
#   private-endpoints  /24  one IP per private endpoint NIC.
locals {
  spoke_cidr = var.settings.spoke_address_space[0]
  hub_cidr   = var.settings.hub_address_space[0]

  delegation_actions = {
    "Microsoft.App/environments"                  = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    "Microsoft.Web/serverFarms"                   = ["Microsoft.Network/virtualNetworks/subnets/action"]
    "Microsoft.ContainerInstance/containerGroups" = ["Microsoft.Network/virtualNetworks/subnets/action"]
    "Microsoft.DBforPostgreSQL/flexibleServers"   = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    "Microsoft.DBforMySQL/flexibleServers"        = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    "Microsoft.Sql/managedInstances" = [
      "Microsoft.Network/virtualNetworks/subnets/join/action",
      "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
      "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
    ]
    "Microsoft.DevOpsInfrastructure/pools" = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
  }

  # vnet: spoke | hub. nsg: attach an NSG. egress: subnet gets NAT Gateway (nat mode) or the firewall
  # default route (firewall mode). required: must stay enabled (consumers depend on it).
  spoke_catalogue = {
    "aks-nodes"          = { prefix = cidrsubnet(local.spoke_cidr, 6, 0), delegation = null, nsg = true, egress = true, required = false }                                            # 10.41.0.0/22
    "aca-infra"          = { prefix = cidrsubnet(local.spoke_cidr, 7, 2), delegation = "Microsoft.App/environments", nsg = true, egress = true, required = true }                     # 10.41.4.0/23
    "aro-master"         = { prefix = cidrsubnet(local.spoke_cidr, 7, 3), delegation = null, nsg = var.settings.aro_preconfigured_nsg, egress = false, required = false }             # 10.41.6.0/23
    "aro-worker"         = { prefix = cidrsubnet(local.spoke_cidr, 7, 4), delegation = null, nsg = var.settings.aro_preconfigured_nsg, egress = false, required = false }             # 10.41.8.0/23
    "compute"            = { prefix = cidrsubnet(local.spoke_cidr, 8, 10), delegation = null, nsg = true, egress = true, required = true }                                            # 10.41.10.0/24
    "private-endpoints"  = { prefix = cidrsubnet(local.spoke_cidr, 8, 11), delegation = null, nsg = true, egress = false, required = true }                                           # 10.41.11.0/24
    "appsvc-integration" = { prefix = cidrsubnet(local.spoke_cidr, 10, 48), delegation = "Microsoft.Web/serverFarms", nsg = true, egress = true, required = true }                    # 10.41.12.0/26
    "flex-integration"   = { prefix = cidrsubnet(local.spoke_cidr, 10, 49), delegation = "Microsoft.App/environments", nsg = true, egress = true, required = false }                  # 10.41.12.64/26
    "aci"                = { prefix = cidrsubnet(local.spoke_cidr, 10, 50), delegation = "Microsoft.ContainerInstance/containerGroups", nsg = true, egress = true, required = false } # 10.41.12.128/26
    "deploy-agents" = {
      prefix     = cidrsubnet(local.spoke_cidr, 10, 51) # 10.41.12.192/26
      delegation = var.settings.deploy_agents_mode == "managed-devops-pool" ? "Microsoft.DevOpsInfrastructure/pools" : null
      nsg        = true, egress = true, required = true
    }
    "postgres"      = { prefix = cidrsubnet(local.spoke_cidr, 11, 104), delegation = "Microsoft.DBforPostgreSQL/flexibleServers", nsg = true, egress = false, required = false } # 10.41.13.0/27
    "mysql"         = { prefix = cidrsubnet(local.spoke_cidr, 11, 105), delegation = "Microsoft.DBforMySQL/flexibleServers", nsg = true, egress = false, required = false }      # 10.41.13.32/27
    "sqlmi"         = { prefix = cidrsubnet(local.spoke_cidr, 10, 53), delegation = "Microsoft.Sql/managedInstances", nsg = true, egress = true, required = false }              # 10.41.13.64/26
    "cassandra-mi"  = { prefix = cidrsubnet(local.spoke_cidr, 10, 54), delegation = null, nsg = true, egress = true, required = false }                                          # 10.41.13.128/26
    "observability" = { prefix = cidrsubnet(local.spoke_cidr, 10, 55), delegation = null, nsg = true, egress = true, required = true }                                           # 10.41.13.192/26
    "batch"         = { prefix = cidrsubnet(local.spoke_cidr, 8, 14), delegation = null, nsg = true, egress = true, required = false }                                           # 10.41.14.0/24
    "sfmc"          = { prefix = cidrsubnet(local.spoke_cidr, 8, 15), delegation = null, nsg = true, egress = true, required = false }                                           # 10.41.15.0/24
    "apim"          = { prefix = cidrsubnet(local.spoke_cidr, 10, 64), delegation = "Microsoft.Web/serverFarms", nsg = true, egress = true, required = false }                   # 10.41.16.0/26
  }

  # Edge subnets: in the hub for hub-spoke, otherwise in the spoke (single-spoke has no hub).
  edge_vnet = var.settings.topology == "hub-spoke" ? "hub" : "spoke"
  edge_catalogue = {
    "AzureFirewallSubnet"           = { vnet = "hub", prefix = cidrsubnet(local.hub_cidr, 6, 0), enabled = var.settings.firewall_subnet, nsg = false } # 10.40.0.0/26
    "AzureFirewallManagementSubnet" = { vnet = "hub", prefix = cidrsubnet(local.hub_cidr, 6, 1), enabled = var.settings.firewall_subnet, nsg = false } # 10.40.0.64/26
    "AzureBastionSubnet" = {
      vnet    = local.edge_vnet
      prefix  = local.edge_vnet == "hub" ? cidrsubnet(local.hub_cidr, 6, 4) : cidrsubnet(local.spoke_cidr, 10, 68) # 10.40.1.0/26 | 10.41.17.0/26
      enabled = var.settings.bastion_subnet, nsg = true
    }
    "appgw" = {
      vnet    = local.edge_vnet
      prefix  = local.edge_vnet == "hub" ? cidrsubnet(local.hub_cidr, 4, 2) : cidrsubnet(local.spoke_cidr, 8, 18) # 10.40.2.0/24 | 10.41.18.0/24
      enabled = var.settings.appgw_subnet, nsg = true
    }
  }

  spoke_subnets = {
    for k, v in local.spoke_catalogue : k => {
      vnet                            = "spoke"
      address_prefix                  = coalesce(try(var.settings.subnets[k].address_prefix, null), v.prefix)
      enabled                         = k == "apim" ? coalesce(try(var.settings.subnets[k].enabled, null), var.settings.apim_subnet) : coalesce(try(var.settings.subnets[k].enabled, null), true)
      delegation                      = v.delegation
      nsg                             = v.nsg
      egress                          = v.egress
      required                        = v.required
      default_outbound_access_enabled = coalesce(try(var.settings.subnets[k].default_outbound_access_enabled, null), false)
    }
  }
  edge_subnets = {
    for k, v in local.edge_catalogue : k => {
      vnet                            = v.vnet
      address_prefix                  = coalesce(try(var.settings.subnets[k].address_prefix, null), v.prefix)
      enabled                         = v.enabled && (v.vnet == "spoke" || var.settings.topology == "hub-spoke")
      delegation                      = null
      nsg                             = v.nsg
      egress                          = false
      required                        = false
      default_outbound_access_enabled = coalesce(try(var.settings.subnets[k].default_outbound_access_enabled, null), false)
    }
  }

  all_subnets = { for k, v in merge(local.spoke_subnets, local.edge_subnets) : k => v if v.enabled }

  # Subnets that receive explicit outbound (NAT Gateway or firewall route). Default outbound access is
  # disabled on every subnet (private subnets), so anything without egress here has no internet path.
  egress_subnets = [for k, v in local.all_subnets : k if v.egress]

  # ARO master subnet must have Private Link service network policies disabled (ARO docs).
  pls_policies_disabled = ["aro-master"]
  service_endpoints = {
    # Lets the bootstrap state storage firewall allow the deploy-agent subnet (bootstrap settings.agent_subnet_ids).
    "deploy-agents" = ["Microsoft.Storage"]
    "aro-master"    = ["Microsoft.ContainerRegistry"]
    "aro-worker"    = ["Microsoft.ContainerRegistry"]
  }
}

# ------------------------------------------------------------------ address plan validation
locals {
  octets = { for k, v in local.all_subnets : k => [for o in split(".", split("/", v.address_prefix)[0]) : tonumber(o)] }
  ranges = {
    for k, v in local.all_subnets : k => {
      start = local.octets[k][0] * 16777216 + local.octets[k][1] * 65536 + local.octets[k][2] * 256 + local.octets[k][3]
      size  = pow(2, 32 - tonumber(split("/", v.address_prefix)[1]))
      vnet  = v.vnet
    }
  }
  vnet_ranges = {
    for name, cidr in { spoke = local.spoke_cidr, hub = local.hub_cidr } : name => {
      start                   = sum([for i, o in split(".", split("/", cidr)[0]) : tonumber(o) * pow(256, 3 - i)])
      size                    = pow(2, 32 - tonumber(split("/", cidr)[1]))
    }
  }
  misaligned_subnets = [for k, v in local.all_subnets : k if cidrhost(v.address_prefix, 0) != split("/", v.address_prefix)[0]]
  subnets_outside_vnet = [
    for k, r in local.ranges : k
    if r.start < local.vnet_ranges[r.vnet].start || r.start + r.size > local.vnet_ranges[r.vnet].start + local.vnet_ranges[r.vnet].size
  ]
  range_keys = sort(keys(local.ranges))
  overlapping_subnets = flatten([
    for i, a in local.range_keys : [
      for j, b in local.range_keys : "${a}<->${b}"
      if i < j && local.ranges[a].vnet == local.ranges[b].vnet &&
      local.ranges[a].start < local.ranges[b].start + local.ranges[b].size &&
      local.ranges[b].start < local.ranges[a].start + local.ranges[a].size
    ]
  ])
  hub_spoke_overlap = var.settings.topology == "hub-spoke" && (
    local.vnet_ranges.hub.start < local.vnet_ranges.spoke.start + local.vnet_ranges.spoke.size &&
    local.vnet_ranges.spoke.start < local.vnet_ranges.hub.start + local.vnet_ranges.hub.size
  )
  missing_required_subnets = [for k, v in local.spoke_subnets : k if v.required && !v.enabled]
}

# ------------------------------------------------------------------ subnets
resource "azurerm_subnet" "this" {
  for_each = local.all_subnets

  name                            = each.key
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = each.value.vnet == "hub" ? azurerm_virtual_network.hub[0].name : azurerm_virtual_network.spoke.name
  address_prefixes                = [each.value.address_prefix]
  default_outbound_access_enabled = each.value.default_outbound_access_enabled
  # NSGs and UDRs apply to private endpoints in this subnet (needed for the deny-by-default NSG to be meaningful).
  private_endpoint_network_policies             = each.key == "private-endpoints" ? "Enabled" : "Disabled"
  private_link_service_network_policies_enabled = !contains(local.pls_policies_disabled, each.key)

  dynamic "service_endpoint" {
    for_each = lookup(local.service_endpoints, each.key, [])
    content {
      service = service_endpoint.value
    }
  }

  dynamic "delegation" {
    for_each = each.value.delegation == null ? [] : [each.value.delegation]
    content {
      name = replace(delegation.value, "/", "-")
      service_delegation {
        name    = delegation.value
        actions = local.delegation_actions[delegation.value]
      }
    }
  }

  lifecycle {
    # Services (SQL MI, ACA, MDP) amend the delegation action list; never fight them.
    ignore_changes = [delegation[0].service_delegation[0].actions]
  }
}
