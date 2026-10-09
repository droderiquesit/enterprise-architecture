# Azure Bastion. Developer SKU: free, no AzureBastionSubnet or public IP, attaches to one VNet (the spoke,
# where the VMs are), limited regions and no peering support. Basic/Standard: AzureBastionSubnet + public IP.
locals {
  bas           = local.s.bastion
  bas_on        = local.bas.enabled
  bas_developer = local.bas.sku == "Developer"
}

resource "azurerm_public_ip" "bastion" {
  count = local.bas_on && !local.bas_developer ? 1 : 0

  name                = "${local.names.public_ip}-bas"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  count = local.bas_on ? 1 : 0

  name                = local.names.bastion
  resource_group_name = local.rg_name
  location            = local.location
  sku                 = local.bas.sku
  virtual_network_id  = local.bas_developer ? var.foundation_network.spoke_vnet_id : null
  tunneling_enabled   = local.bas.sku == "Standard" ? true : null
  tags                = local.tags

  dynamic "ip_configuration" {
    for_each = local.bas_developer ? [] : [1]
    content {
      name                 = "primary"
      subnet_id            = local.subnets["AzureBastionSubnet"].id
      public_ip_address_id = azurerm_public_ip.bastion[0].id
    }
  }

  lifecycle {
    precondition {
      condition     = local.bas_developer || contains(keys(local.subnets), "AzureBastionSubnet")
      error_message = "Basic/Standard Bastion needs AzureBastionSubnet (foundation-network settings.bastion_subnet = true)."
    }
  }
}
