mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-edge-dev-sec" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/appgw"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip"
      ip_address = "20.0.0.10"
    }
  }
  mock_resource "azurerm_web_application_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/waf" }
  }
  mock_resource "azurerm_api_management" {
    defaults = {
      id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim"
      gateway_url = "https://eh-apim-edge-dev-sec-abcde.azure-api.net"
    }
  }
  mock_resource "azurerm_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/firewallPolicies/fwp" }
  }
  mock_resource "azurerm_cdn_frontdoor_profile" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Cdn/profiles/afd" }
  }
  mock_resource "azurerm_cdn_frontdoor_endpoint" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Cdn/profiles/afd/afdEndpoints/ep"
      host_name = "eh-dev-abcde.z01.azurefd.net"
    }
  }
  mock_resource "azurerm_cdn_frontdoor_origin_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Cdn/profiles/afd/originGroups/default" }
  }
  mock_resource "azurerm_cdn_frontdoor_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/frontDoorWebApplicationFirewallPolicies/waf" }
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
  foundation_network = {
    topology      = "hub-spoke"
    hub_vnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub"
    spoke_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke"
    subnets = {
      "AzureFirewallSubnet"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub/subnets/AzureFirewallSubnet" }
      "AzureFirewallManagementSubnet" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub/subnets/AzureFirewallManagementSubnet" }
      "AzureBastionSubnet"            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub/subnets/AzureBastionSubnet" }
      "appgw"                         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub/subnets/appgw" }
      "apim"                          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/apim" }
    }
  }
}

run "everything_off_by_default" {
  command = plan

  assert {
    condition = (length(azurerm_resource_group.edge) + length(azurerm_application_gateway.this) + length(azurerm_cdn_frontdoor_profile.this) +
    length(azurerm_api_management.this) + length(azurerm_firewall.this) + length(azurerm_bastion_host.this) + length(azurerm_public_ip.appgw)) == 0
    error_message = "edge components must be absent by default"
  }
  assert {
    condition     = length(output.contract.public_endpoints) == 0 && output.contract.app_gateway.enabled == false
    error_message = "no public endpoints by default"
  }
}

run "all_components" {
  command = plan
  variables {
    settings = {
      app_gateway = {
        enabled       = true
        backend_fqdns = ["hello-bff.internal.example"]
      }
      front_door = {
        enabled  = true
        sku_name = "Premium_AzureFrontDoor"
        origins = [{
          name      = "bff"
          host_name = "hello-bff.example"
          private_link = {
            target_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Web/sites/app"
            location    = "swedencentral"
            target_type = "sites"
          }
        }]
      }
      apim     = { enabled = true, vnet_integration = true }
      firewall = { enabled = true }
      bastion  = { enabled = true, sku = "Basic" }
    }
    tls_certificate_pfx      = "UEZYLXRlc3Q="
    tls_certificate_password = "test-only"
  }

  assert {
    condition     = azurerm_application_gateway.this[0].sku[0].name == "WAF_v2" && one([for c in azurerm_application_gateway.this[0].ssl_certificate : c.key_vault_secret_id]) == null
    error_message = "WAF_v2 with the pipeline-provided PFX (no Key Vault reference)"
  }
  assert {
    condition     = length(azurerm_application_gateway.this[0].identity) == 0
    error_message = "no App Gateway identity is needed without Key Vault"
  }
  assert {
    condition     = length(azurerm_cdn_frontdoor_firewall_policy.this[0].managed_rule) == 2 && azurerm_cdn_frontdoor_origin.this["bff"].private_link[0].target_type == "sites"
    error_message = "Premium Front Door: managed WAF rules + private link origin"
  }
  assert {
    condition     = azurerm_api_management.this[0].sku_name == "StandardV2_1" && azurerm_api_management.this[0].virtual_network_type == "External"
    error_message = "APIM StandardV2 with VNet integration"
  }
  assert {
    condition     = azurerm_firewall.this[0].sku_tier == "Basic" && length(azurerm_firewall.this[0].management_ip_configuration) == 1
    error_message = "Basic firewall requires a management IP configuration"
  }
  assert {
    condition     = length(azurerm_bastion_host.this[0].ip_configuration) == 1 && azurerm_bastion_host.this[0].sku == "Basic"
    error_message = "Basic Bastion uses AzureBastionSubnet"
  }
  assert {
    condition     = contains(output.contract.public_endpoints, "https://eh-dev-abcde.z01.azurefd.net")
    error_message = "contract lists public endpoints"
  }
}

run "bastion_developer_needs_no_subnet" {
  command = plan
  variables {
    foundation_network = {
      spoke_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke"
      subnets       = {}
    }
    settings = { bastion = { enabled = true } }
  }
  assert {
    condition     = azurerm_bastion_host.this[0].sku == "Developer" && length(azurerm_bastion_host.this[0].ip_configuration) == 0 && length(azurerm_public_ip.bastion) == 0
    error_message = "Developer Bastion: no subnet, no public IP"
  }
}

run "firewall_requires_hub" {
  command = plan
  variables {
    foundation_network = {
      topology      = "single-spoke"
      spoke_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke"
      subnets       = {}
    }
    settings = { firewall = { enabled = true } }
  }
  expect_failures = [azurerm_firewall.this[0]]
}

run "app_gateway_requires_certificate" {
  command = plan
  variables {
    settings = { app_gateway = { enabled = true, backend_fqdns = ["x.example"] } }
  }
  expect_failures = [azurerm_application_gateway.this[0]]
}

run "app_gateway_requires_backend" {
  command = plan
  variables {
    settings                 = { app_gateway = { enabled = true } }
    tls_certificate_pfx      = "UEZYLXRlc3Q="
    tls_certificate_password = "test-only"
  }
  expect_failures = [var.settings]
}
