output "contract" {
  description = "foundation-network contract v1 (catalog/contracts/foundation-network.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.network.name
    resource_group_id   = azurerm_resource_group.network.id
    location            = local.location
    topology            = var.settings.topology
    hub_vnet_id         = local.hub ? azurerm_virtual_network.hub[0].id : null
    hub_vnet_name       = local.hub ? azurerm_virtual_network.hub[0].name : null
    spoke_vnet_id       = azurerm_virtual_network.spoke.id
    spoke_vnet_name     = azurerm_virtual_network.spoke.name
    spoke_address_space = var.settings.spoke_address_space
    subnets = {
      for k, v in local.all_subnets : k => {
        id                 = azurerm_subnet.this[k].id
        name               = azurerm_subnet.this[k].name
        address_prefix     = v.address_prefix
        vnet_id            = v.vnet == "hub" ? azurerm_virtual_network.hub[0].id : azurerm_virtual_network.spoke.id
        delegation         = v.delegation
        nsg_id             = v.nsg ? azurerm_network_security_group.this[k].id : null
        explicit_egress    = v.egress
        default_outbound   = v.default_outbound_access_enabled
        route_table_id     = k == "sqlmi" ? azurerm_route_table.sqlmi[0].id : (local.firewall && v.egress ? azurerm_route_table.spoke_egress[0].id : null)
        nat_gateway_egress = local.nat && v.egress
      }
    }
    # `documentdb` is an alias of `mongocluster` (same zone) for consumers that key by component name.
    private_dns_zones = merge(
      {
        for k, v in local.private_dns_zones : k => {
          id   = azurerm_private_dns_zone.this[k].id
          name = azurerm_private_dns_zone.this[k].name
        }
      },
      contains(keys(local.private_dns_zones), "mongocluster") ? {
        documentdb = {
          id   = azurerm_private_dns_zone.this["mongocluster"].id
          name = azurerm_private_dns_zone.this["mongocluster"].name
        }
      } : {}
    )
    egress = {
      type                = var.settings.egress
      public_ips          = local.nat ? azurerm_public_ip.nat[*].ip_address : []
      nat_gateway_id      = local.nat ? azurerm_nat_gateway.this[0].id : null
      firewall_private_ip = local.firewall_private_ip
    }
    internal_dns_zone    = azurerm_private_dns_zone.internal.name
    internal_dns_zone_id = azurerm_private_dns_zone.internal.id
  }
}
