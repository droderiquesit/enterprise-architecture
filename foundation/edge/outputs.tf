output "contract" {
  description = "foundation-edge contract v1 (catalog/contracts/foundation-edge.v1.schema.json). Public endpoints only; no secrets."
  value = {
    resource_group_name = local.rg_name
    app_gateway = {
      enabled   = local.agw_on
      id        = local.agw_on ? azurerm_application_gateway.this[0].id : null
      public_ip = local.agw_on ? azurerm_public_ip.appgw[0].ip_address : null
    }
    front_door = {
      enabled           = local.afd_on
      profile_id        = local.afd_on ? azurerm_cdn_frontdoor_profile.this[0].id : null
      endpoint_hostname = local.afd_on ? azurerm_cdn_frontdoor_endpoint.this[0].host_name : null
      # Front Door sends this header; origins should only accept traffic carrying it.
      front_door_id = local.afd_on ? azurerm_cdn_frontdoor_profile.this[0].resource_guid : null
    }
    apim = {
      enabled     = local.apim_on
      id          = local.apim_on ? azurerm_api_management.this[0].id : null
      gateway_url = local.apim_on ? azurerm_api_management.this[0].gateway_url : null
    }
    firewall = {
      enabled    = local.fw_on
      id         = local.fw_on ? azurerm_firewall.this[0].id : null
      private_ip = local.fw_on ? azurerm_firewall.this[0].ip_configuration[0].private_ip_address : null
      public_ips = local.fw_on ? [azurerm_public_ip.firewall[0].ip_address] : []
    }
    bastion = {
      enabled  = local.bas_on
      id       = local.bas_on ? azurerm_bastion_host.this[0].id : null
      sku      = local.bas.sku
      dns_name = local.bas_on ? azurerm_bastion_host.this[0].dns_name : null
    }
    public_endpoints = compact(concat(
      local.agw_on ? ["https://${coalesce(local.agw.listener_host_name, azurerm_public_ip.appgw[0].ip_address)}"] : [],
      local.afd_on ? ["https://${azurerm_cdn_frontdoor_endpoint.this[0].host_name}"] : [],
      local.apim_on ? [azurerm_api_management.this[0].gateway_url] : [],
    ))
  }
}
