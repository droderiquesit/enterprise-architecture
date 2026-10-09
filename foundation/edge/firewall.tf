# Azure Firewall (Basic/Standard) in the hub + policy. After it exists, switch foundation-network
# settings.egress to "firewall" (route 0.0.0.0/0 -> firewall private IP); see README "Switching egress".
locals {
  fw    = local.s.firewall
  fw_on = local.fw.enabled
}

resource "azurerm_public_ip" "firewall" {
  count = local.fw_on ? 1 : 0

  name                = "${local.names.public_ip}-afw"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.fw.zones
  tags                = local.tags
}

# Basic SKU requires a management IP configuration (AzureFirewallManagementSubnet + its own public IP).
resource "azurerm_public_ip" "firewall_mgmt" {
  count = local.fw_on && local.fw.sku_tier == "Basic" ? 1 : 0

  name                = "${local.names.public_ip}-afw-mgmt"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.fw.zones
  tags                = local.tags
}

resource "azurerm_firewall_policy" "this" {
  #checkov:skip=CKV_AZURE_220:IDPS is an Azure Firewall Premium feature; the lab supports Basic/Standard only.
  count = local.fw_on ? 1 : 0

  name                     = "${local.names.firewall}-policy"
  resource_group_name      = local.rg_name
  location                 = local.location
  sku                      = local.fw.sku_tier
  threat_intelligence_mode = local.fw.sku_tier == "Basic" ? "Alert" : "Deny" # Basic supports Alert only
  tags                     = local.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  count = local.fw_on ? 1 : 0

  name               = "lab-egress"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 200

  application_rule_collection {
    name     = "allow-required-fqdns"
    priority = 200
    action   = "Allow"

    rule {
      name              = "https-fqdns"
      source_addresses  = var.foundation_network.spoke_address_space
      destination_fqdns = local.fw.allowed_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }

    dynamic "rule" {
      for_each = length(local.fw.allowed_fqdn_tags) > 0 ? [1] : []
      content {
        name                  = "fqdn-tags"
        source_addresses      = var.foundation_network.spoke_address_space
        destination_fqdn_tags = local.fw.allowed_fqdn_tags
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }

  network_rule_collection {
    name     = "allow-platform"
    priority = 300
    action   = "Allow"

    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = var.foundation_network.spoke_address_space
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
    rule {
      name                  = "azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = var.foundation_network.spoke_address_space
      destination_addresses = ["AzureMonitor"]
      destination_ports     = ["443"]
    }
  }
}

resource "azurerm_firewall" "this" {
  #checkov:skip=CKV_AZURE_216:Threat intelligence mode is set on the attached firewall policy (Deny on Standard; Basic supports Alert only).
  count = local.fw_on ? 1 : 0

  name                = local.names.firewall
  resource_group_name = local.rg_name
  location            = local.location
  sku_name            = "AZFW_VNet"
  sku_tier            = local.fw.sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this[0].id
  zones               = local.fw.zones
  tags                = local.tags

  ip_configuration {
    name                 = "primary"
    subnet_id            = local.subnets["AzureFirewallSubnet"].id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  dynamic "management_ip_configuration" {
    for_each = local.fw.sku_tier == "Basic" ? [1] : []
    content {
      name                 = "management"
      subnet_id            = local.subnets["AzureFirewallManagementSubnet"].id
      public_ip_address_id = azurerm_public_ip.firewall_mgmt[0].id
    }
  }

  lifecycle {
    precondition {
      condition     = local.hub && contains(keys(local.subnets), "AzureFirewallSubnet") && (local.fw.sku_tier != "Basic" || contains(keys(local.subnets), "AzureFirewallManagementSubnet"))
      error_message = "Azure Firewall needs hub-spoke topology with firewall subnets (foundation-network settings.topology = hub-spoke, firewall_subnet = true)."
    }
  }
}
