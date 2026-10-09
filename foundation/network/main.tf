module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "network"
}

module "tags" {
  source      = "../modules/tags"
  environment = var.environment
  component   = "foundation-network"
  layer       = "foundation"
  domain      = "network"
}

locals {
  names    = module.naming.names
  tags     = module.tags.tags
  location = var.environment.location
  hub      = var.settings.topology == "hub-spoke"
  nat      = var.settings.egress == "nat-gateway"
  firewall = var.settings.egress == "firewall"
  # Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet, so the spoke default
  # route can be computed before foundation-edge creates the firewall (see README "Switching egress to firewall").
  firewall_private_ip = var.settings.firewall_subnet && local.hub ? cidrhost(local.all_subnets["AzureFirewallSubnet"].address_prefix, 4) : null
}

resource "azurerm_resource_group" "network" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# ------------------------------------------------------------------ virtual networks
resource "azurerm_virtual_network" "spoke" {
  name                = "${local.names.virtual_network}-spoke"
  resource_group_name = azurerm_resource_group.network.name
  location            = local.location
  address_space       = var.settings.spoke_address_space
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = length(local.misaligned_subnets) == 0
      error_message = "Subnet prefixes must be network addresses (host bits zero): ${join(", ", local.misaligned_subnets)}."
    }
    precondition {
      condition     = length(local.subnets_outside_vnet) == 0
      error_message = "Subnets do not fit their VNet address space: ${join(", ", local.subnets_outside_vnet)}."
    }
    precondition {
      condition     = length(local.overlapping_subnets) == 0
      error_message = "Overlapping subnets: ${join(", ", local.overlapping_subnets)}."
    }
    precondition {
      condition     = !local.hub_spoke_overlap
      error_message = "hub_address_space and spoke_address_space overlap."
    }
    precondition {
      condition     = length(local.missing_required_subnets) == 0
      error_message = "These subnets are required by the foundation-network contract and cannot be disabled: ${join(", ", local.missing_required_subnets)}."
    }
  }
}

resource "azurerm_virtual_network" "hub" {
  count = local.hub ? 1 : 0

  name                = "${local.names.virtual_network}-hub"
  resource_group_name = azurerm_resource_group.network.name
  location            = local.location
  address_space       = var.settings.hub_address_space
  tags                = local.tags
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count = local.hub ? 1 : 0

  name                         = "hub-to-spoke"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.hub[0].name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count = local.hub ? 1 : 0

  name                         = "spoke-to-hub"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

# ------------------------------------------------------------------ egress: NAT Gateway
resource "azurerm_public_ip" "nat" {
  count = local.nat ? var.settings.nat_gateway.public_ip_count : 0

  name                = "${local.names.public_ip}-nat-${count.index}"
  resource_group_name = azurerm_resource_group.network.name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.settings.nat_gateway.zones
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  count = local.nat ? 1 : 0

  name                    = local.names.nat_gateway
  resource_group_name     = azurerm_resource_group.network.name
  location                = local.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.settings.nat_gateway.idle_timeout_in_minutes
  zones                   = var.settings.nat_gateway.zones
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = local.nat ? var.settings.nat_gateway.public_ip_count : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[count.index].id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  for_each = local.nat ? toset(local.egress_subnets) : toset([])

  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# ------------------------------------------------------------------ egress: firewall default route
resource "azurerm_route_table" "spoke_egress" {
  count = local.firewall ? 1 : 0

  name                          = "${local.names.route_table}-spoke-egress"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = local.location
  bgp_route_propagation_enabled = false
  tags                          = local.tags
}

resource "azurerm_route" "default_to_firewall" {
  count = local.firewall ? 1 : 0

  name                   = "default-to-firewall"
  resource_group_name    = azurerm_resource_group.network.name
  route_table_name       = azurerm_route_table.spoke_egress[0].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = local.firewall_private_ip
}

resource "azurerm_subnet_route_table_association" "spoke_egress" {
  # sqlmi keeps its own service-managed route table.
  for_each = local.firewall ? toset([for k in local.egress_subnets : k if k != "sqlmi"]) : toset([])

  subnet_id      = azurerm_subnet.this[each.key].id
  route_table_id = azurerm_route_table.spoke_egress[0].id
}

# SQL Managed Instance requires a route table (and NSG) on its delegated subnet; the service
# (service-aided subnet configuration / network intent policy) adds and owns the routes.
resource "azurerm_route_table" "sqlmi" {
  count = contains(keys(local.all_subnets), "sqlmi") ? 1 : 0

  name                          = "${local.names.route_table}-sqlmi"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = local.location
  bgp_route_propagation_enabled = true
  tags                          = local.tags

  lifecycle {
    ignore_changes = [route]
  }
}

resource "azurerm_subnet_route_table_association" "sqlmi" {
  count = contains(keys(local.all_subnets), "sqlmi") ? 1 : 0

  subnet_id      = azurerm_subnet.this["sqlmi"].id
  route_table_id = azurerm_route_table.sqlmi[0].id
}
