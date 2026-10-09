# API Management. Default StandardV2_1 (v2 tiers: fast provisioning, outbound VNet integration on
# StandardV2/PremiumV2 via a subnet delegated to Microsoft.Web/serverFarms with an NSG allowing KeyVault 443).
locals {
  apim    = local.s.apim
  apim_on = local.apim.enabled
}

resource "azurerm_api_management" "this" {
  #checkov:skip=CKV_AZURE_174:public_network_access_enabled must be true at creation (provider constraint) and only affects the management plane.
  count = local.apim_on ? 1 : 0

  name                = "${local.names.api_management}-${module.naming.suffix}"
  resource_group_name = local.rg_name
  location            = local.location
  sku_name            = local.apim.sku_name
  publisher_name      = local.apim.publisher_name
  publisher_email     = coalesce(local.apim.publisher_email, var.environment.owner)
  # Management-plane only; must be true at creation (provider docs). Gateway exposure is governed by the SKU/VNet mode.
  public_network_access_enabled = true
  virtual_network_type          = local.apim.vnet_integration ? "External" : "None"
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  dynamic "virtual_network_configuration" {
    for_each = local.apim.vnet_integration ? [1] : []
    content {
      subnet_id = local.subnets["apim"].id
    }
  }

  security {
    frontend_ssl30_enabled = false
    frontend_tls10_enabled = false
    frontend_tls11_enabled = false
    backend_ssl30_enabled  = false
    backend_tls10_enabled  = false
    backend_tls11_enabled  = false
  }

  lifecycle {
    precondition {
      condition     = !local.apim.vnet_integration || contains(keys(local.subnets), "apim")
      error_message = "apim.vnet_integration needs the apim subnet (foundation-network settings.apim_subnet = true)."
    }
  }
}
