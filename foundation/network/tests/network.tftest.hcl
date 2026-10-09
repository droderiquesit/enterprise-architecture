mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-network-dev-sec" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg" }
  }
  mock_resource "azurerm_route_table" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/routeTables/rt" }
  }
  mock_resource "azurerm_nat_gateway" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/natGateways/ng" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip"
      ip_address = "20.0.0.1"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/zone" }
  }
}

variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
}

run "minimal_single_spoke_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.hub) == 0 && length(azurerm_virtual_network_peering.hub_to_spoke) == 0
    error_message = "single-spoke must not create a hub or peering"
  }
  assert {
    condition     = length(azurerm_route_table.spoke_egress) == 0 && length(azurerm_route.default_to_firewall) == 0
    error_message = "single-spoke must not route to a firewall"
  }
  assert {
    condition     = !contains(keys(azurerm_subnet.this), "AzureFirewallSubnet") && !contains(keys(azurerm_subnet.this), "AzureBastionSubnet")
    error_message = "edge subnets are off by default"
  }
  assert {
    condition     = length(azurerm_nat_gateway.this) == 1 && length(azurerm_public_ip.nat) == 1
    error_message = "NAT Gateway egress expected by default"
  }
  assert {
    condition     = alltrue([for k in ["compute", "aks-nodes", "aca-infra", "deploy-agents", "observability", "batch"] : contains(keys(azurerm_subnet_nat_gateway_association.this), k)])
    error_message = "egress subnets must be associated with the NAT Gateway"
  }
  assert {
    condition     = !contains(keys(azurerm_subnet_nat_gateway_association.this), "private-endpoints") && !contains(keys(azurerm_subnet_nat_gateway_association.this), "aro-master")
    error_message = "private-endpoints / ARO subnets get no NAT Gateway"
  }
  assert {
    condition     = alltrue([for s in azurerm_subnet.this : s.default_outbound_access_enabled == false])
    error_message = "default outbound access must be disabled on every subnet"
  }
  assert {
    condition = alltrue([for k, d in {
      "aca-infra"          = "Microsoft.App/environments"
      "flex-integration"   = "Microsoft.App/environments"
      "appsvc-integration" = "Microsoft.Web/serverFarms"
      "aci"                = "Microsoft.ContainerInstance/containerGroups"
      "postgres"           = "Microsoft.DBforPostgreSQL/flexibleServers"
      "mysql"              = "Microsoft.DBforMySQL/flexibleServers"
      "sqlmi"              = "Microsoft.Sql/managedInstances"
    } : azurerm_subnet.this[k].delegation[0].service_delegation[0].name == d])
    error_message = "delegated subnets must carry the documented service delegation"
  }
  assert {
    condition     = alltrue([for k in ["compute", "aks-nodes", "private-endpoints", "deploy-agents", "observability", "cassandra-mi", "batch", "sfmc"] : length(azurerm_subnet.this[k].delegation) == 0])
    error_message = "non-delegated subnets must have no delegation (VMSS agents mode)"
  }
  assert {
    condition     = keys(azurerm_subnet_network_security_group_association.this) == keys(azurerm_network_security_group.this) && length(azurerm_network_security_group.this) == length([for k, s in azurerm_subnet.this : k if !startswith(k, "aro-")])
    error_message = "every subnet that allows an NSG (all except ARO by default) must have one associated"
  }
  assert {
    condition     = azurerm_network_security_rule.this["compute/DenyInternetInbound"].access == "Deny" && azurerm_network_security_rule.this["compute/DenyInternetInbound"].source_address_prefix == "Internet"
    error_message = "inbound internet must be denied by default"
  }
  assert {
    condition     = azurerm_network_security_rule.this["sqlmi/AllowAzureLoadBalancerInbound"].access == "Allow"
    error_message = "AzureLoadBalancer must be allowed"
  }
  assert {
    condition     = length(azurerm_route_table.sqlmi) == 1 && length(azurerm_subnet_route_table_association.sqlmi) == 1
    error_message = "SQL MI subnet needs a route table"
  }
  assert {
    condition     = azurerm_subnet.this["private-endpoints"].private_endpoint_network_policies == "Enabled"
    error_message = "NSG must apply to private endpoints"
  }
  assert {
    condition     = azurerm_subnet.this["aro-master"].private_link_service_network_policies_enabled == false
    error_message = "ARO master subnet needs PLS network policies disabled"
  }
  assert {
    condition     = azurerm_subnet.this["aca-infra"].address_prefixes[0] == "10.41.4.0/23" && azurerm_subnet.this["aks-nodes"].address_prefixes[0] == "10.41.0.0/22" && azurerm_subnet.this["deploy-agents"].address_prefixes[0] == "10.41.12.192/26"
    error_message = "default address plan changed unexpectedly"
  }
  assert {
    condition = alltrue([for k, n in {
      blob         = "privatelink.blob.core.windows.net"
      redis        = "privatelink.redis.azure.net"
      mongocluster = "privatelink.mongocluster.cosmos.azure.com"
      aca          = "privatelink.swedencentral.azurecontainerapps.io"
      kusto        = "privatelink.swedencentral.kusto.windows.net"
      sql          = "privatelink.database.windows.net"
    } : azurerm_private_dns_zone.this[k].name == n])
    error_message = "private DNS zone names must match Microsoft's recommended zone names"
  }
  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.this) == length(azurerm_private_dns_zone.this)
    error_message = "single-spoke: one VNet link per zone"
  }
  assert {
    condition     = output.contract.topology == "single-spoke" && output.contract.hub_vnet_id == null && output.contract.egress.type == "nat-gateway"
    error_message = "contract topology/egress"
  }
  assert {
    condition     = alltrue([for k in ["compute", "private-endpoints", "aca-infra", "appsvc-integration", "deploy-agents", "observability"] : can(regex("^/subscriptions/[^/]+/", output.contract.subnets[k].id))])
    error_message = "contract must expose required subnets with ARM ids"
  }
  assert {
    condition     = can(regex("^/subscriptions/[^/]+/", output.contract.private_dns_zones["blob"].id)) && output.contract.internal_dns_zone == "dev.eh.lab.internal"
    error_message = "contract DNS zones"
  }
  assert {
    condition     = output.contract.private_dns_zones["documentdb"].name == "privatelink.mongocluster.cosmos.azure.com"
    error_message = "documentdb alias must point at the mongocluster zone"
  }
}

run "hub_spoke_with_firewall_egress" {
  command = plan

  variables {
    settings = {
      topology        = "hub-spoke"
      egress          = "firewall"
      firewall_subnet = true
      bastion_subnet  = true
      appgw_subnet    = true
    }
  }

  assert {
    condition     = length(azurerm_virtual_network.hub) == 1 && length(azurerm_virtual_network_peering.hub_to_spoke) == 1 && length(azurerm_virtual_network_peering.spoke_to_hub) == 1
    error_message = "hub-spoke must create hub and both peerings"
  }
  assert {
    condition     = length(azurerm_nat_gateway.this) == 0 && length(azurerm_subnet_nat_gateway_association.this) == 0
    error_message = "firewall egress must not create a NAT Gateway"
  }
  assert {
    condition     = azurerm_route.default_to_firewall[0].next_hop_in_ip_address == "10.40.0.4" && azurerm_route.default_to_firewall[0].address_prefix == "0.0.0.0/0"
    error_message = "spoke default route must point to the firewall's first usable IP"
  }
  assert {
    condition     = contains(keys(azurerm_subnet_route_table_association.spoke_egress), "compute") && !contains(keys(azurerm_subnet_route_table_association.spoke_egress), "sqlmi")
    error_message = "egress subnets route to firewall; sqlmi keeps its own route table"
  }
  assert {
    condition     = azurerm_subnet.this["AzureFirewallSubnet"].address_prefixes[0] == "10.40.0.0/26" && !contains(keys(azurerm_network_security_group.this), "AzureFirewallSubnet")
    error_message = "firewall subnet lives in the hub and has no NSG"
  }
  assert {
    condition     = azurerm_subnet.this["AzureBastionSubnet"].address_prefixes[0] == "10.40.1.0/26" && azurerm_network_security_rule.this["AzureBastionSubnet/AllowGatewayManagerInbound"].destination_port_range == "443"
    error_message = "Bastion subnet in hub with required NSG rules"
  }
  assert {
    condition     = azurerm_network_security_rule.this["appgw/AllowGatewayManagerInbound"].destination_port_range == "65200-65535"
    error_message = "App Gateway v2 infrastructure ports must be allowed"
  }
  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.this) == 2 * length(azurerm_private_dns_zone.this)
    error_message = "hub-spoke: zones linked to both VNets"
  }
  assert {
    condition     = output.contract.egress.firewall_private_ip == "10.40.0.4"
    error_message = "contract firewall ip"
  }
}

run "managed_devops_pool_delegation" {
  command = plan
  variables {
    settings = { deploy_agents_mode = "managed-devops-pool" }
  }
  assert {
    condition     = azurerm_subnet.this["deploy-agents"].delegation[0].service_delegation[0].name == "Microsoft.DevOpsInfrastructure/pools"
    error_message = "MDP mode delegates deploy-agents"
  }
}

run "overlapping_subnets_rejected" {
  command = plan
  variables {
    settings = { subnets = { compute = { address_prefix = "10.41.0.0/24" } } }
  }
  expect_failures = [azurerm_virtual_network.spoke]
}

run "subnet_outside_vnet_rejected" {
  command = plan
  variables {
    settings = { subnets = { compute = { address_prefix = "10.99.0.0/24" } } }
  }
  expect_failures = [azurerm_virtual_network.spoke]
}

run "required_subnet_cannot_be_disabled" {
  command = plan
  variables {
    settings = { subnets = { "private-endpoints" = { enabled = false } } }
  }
  expect_failures = [azurerm_virtual_network.spoke]
}

run "firewall_requires_hub" {
  command = plan
  variables {
    settings = { egress = "firewall", firewall_subnet = true }
  }
  expect_failures = [var.settings]
}
