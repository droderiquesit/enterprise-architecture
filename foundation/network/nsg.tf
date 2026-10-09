# One NSG per subnet that allows NSGs. Rules are separate azurerm_network_security_rule resources and the
# NSG ignores inline rule drift, because SQL MI (network intent policy) and ARO add their own rules.
#
# Not attached: AzureFirewallSubnet / AzureFirewallManagementSubnet (NSGs not supported), ARO subnets unless
# settings.aro_preconfigured_nsg (ARO's resource provider manages its own NSG otherwise).
locals {
  nsg_subnets = { for k, v in local.all_subnets : k => v if v.nsg }

  baseline_rules = [
    { name = "AllowAzureLoadBalancerInbound", priority = 4000, direction = "Inbound", access = "Allow", protocol = "*", source = "AzureLoadBalancer", destination = "*", ports = ["*"] },
    { name = "DenyInternetInbound", priority = 4096, direction = "Inbound", access = "Deny", protocol = "*", source = "Internet", destination = "*", ports = ["*"] },
  ]

  specific_rules = {
    "AzureBastionSubnet" = [
      # Required Bastion (Basic/Standard/Premium) rules: https://learn.microsoft.com/azure/bastion/bastion-nsg
      { name = "AllowHttpsInbound", priority = 120, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "Internet", destination = "*", ports = ["443"] },
      { name = "AllowGatewayManagerInbound", priority = 130, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "GatewayManager", destination = "*", ports = ["443"] },
      { name = "AllowAzureLoadBalancerHttpsInbound", priority = 140, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "AzureLoadBalancer", destination = "*", ports = ["443"] },
      { name = "AllowBastionHostCommunicationInbound", priority = 150, direction = "Inbound", access = "Allow", protocol = "*", source = "VirtualNetwork", destination = "VirtualNetwork", ports = ["8080", "5701"] },
      { name = "AllowSshRdpOutbound", priority = 100, direction = "Outbound", access = "Allow", protocol = "*", source = "*", destination = "VirtualNetwork", ports = ["22", "3389"] },
      { name = "AllowAzureCloudOutbound", priority = 110, direction = "Outbound", access = "Allow", protocol = "Tcp", source = "*", destination = "AzureCloud", ports = ["443"] },
      { name = "AllowBastionCommunicationOutbound", priority = 120, direction = "Outbound", access = "Allow", protocol = "*", source = "VirtualNetwork", destination = "VirtualNetwork", ports = ["8080", "5701"] },
      { name = "AllowHttpOutbound", priority = 130, direction = "Outbound", access = "Allow", protocol = "*", source = "*", destination = "Internet", ports = ["80"] },
    ]
    "appgw" = [
      # Application Gateway v2 infrastructure ports + listeners: https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure
      { name = "AllowGatewayManagerInbound", priority = 100, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "GatewayManager", destination = "*", ports = ["65200-65535"] },
      { name = "AllowListenersInbound", priority = 110, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "Internet", destination = "*", ports = [for p in var.settings.appgw_listener_ports : tostring(p)] },
    ]
    "apim" = [
      # API Management v2 VNet integration dependency: https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
      { name = "AllowKeyVaultOutbound", priority = 100, direction = "Outbound", access = "Allow", protocol = "Tcp", source = "VirtualNetwork", destination = "AzureKeyVault", ports = ["443"] },
    ]
    "aks-nodes" = var.settings.aks_public_ingress ? [
      { name = "AllowInternetHttpInbound", priority = 200, direction = "Inbound", access = "Allow", protocol = "Tcp", source = "Internet", destination = "*", ports = ["80", "443"] },
    ] : []
  }

  nsg_rules = merge([
    for subnet, _ in local.nsg_subnets : {
      for rule in concat(lookup(local.specific_rules, subnet, []), local.baseline_rules) : "${subnet}/${rule.name}" => merge(rule, { subnet = subnet })
    }
  ]...)
}

resource "azurerm_network_security_group" "this" {
  for_each = local.nsg_subnets

  name                = "${local.names.network_security_group}-${lower(each.key)}"
  resource_group_name = azurerm_resource_group.network.name
  location            = local.location
  tags                = local.tags

  lifecycle {
    ignore_changes = [security_rule]
  }
}

resource "azurerm_network_security_rule" "this" {
  for_each = local.nsg_rules

  name                        = each.value.name
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.this[each.value.subnet].name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  source_address_prefix       = each.value.source
  destination_address_prefix  = each.value.destination
  destination_port_range      = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges     = length(each.value.ports) > 1 ? each.value.ports : null
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = local.nsg_subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}
