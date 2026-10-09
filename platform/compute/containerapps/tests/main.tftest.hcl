mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aca-dev-sec/providers/Microsoft.App/managedEnvironments/eh-cae-aca-dev-sec"
      default_domain    = "kindstone-12345678.swedencentral.azurecontainerapps.io"
      static_ip_address = "10.41.2.200"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aca-dev-sec/providers/Microsoft.Network/privateDnsZones/kindstone-12345678.swedencentral.azurecontainerapps.io"
    }
  }
}

# BEGIN FIXTURE (generated): upstream contract shapes with valid Azure IDs.
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
    resource_group_name = "rg-net"
    location            = "swedencentral"
    spoke_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    hub_vnet_id         = null
    subnets = {
      "compute"            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-compute", name = "snet-compute", address_prefix = "10.41.0.0/24" }
      "aks-nodes"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aks-nodes", name = "snet-aks-nodes", address_prefix = "10.41.1.0/24" }
      "aca-infra"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca-infra", name = "snet-aca-infra", address_prefix = "10.41.2.0/24" }
      "appsvc-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration", name = "snet-appsvc-integration", address_prefix = "10.41.3.0/24" }
      "flex-integration"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration", name = "snet-flex-integration", address_prefix = "10.41.4.0/24" }
      "aci"                = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aci", name = "snet-aci", address_prefix = "10.41.5.0/24" }
      "private-endpoints"  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-private-endpoints", name = "snet-private-endpoints", address_prefix = "10.41.6.0/24" }
      "postgres"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-postgres", name = "snet-postgres", address_prefix = "10.41.7.0/24" }
      "mysql"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-mysql", name = "snet-mysql", address_prefix = "10.41.8.0/24" }
      "sqlmi"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sqlmi", name = "snet-sqlmi", address_prefix = "10.41.9.0/24" }
      "cassandra-mi"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-cassandra-mi", name = "snet-cassandra-mi", address_prefix = "10.41.10.0/24" }
      "batch"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-batch", name = "snet-batch", address_prefix = "10.41.11.0/24" }
      "deploy-agents"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-deploy-agents", name = "snet-deploy-agents", address_prefix = "10.41.12.0/24" }
      "observability"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-observability", name = "snet-observability", address_prefix = "10.41.13.0/24" }
      "sfmc"               = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sfmc", name = "snet-sfmc", address_prefix = "10.41.14.0/24" }
      "aro-master"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-master", name = "snet-aro-master", address_prefix = "10.41.15.0/24" }
      "aro-worker"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-worker", name = "snet-aro-worker", address_prefix = "10.41.16.0/24" }
    }
  }
  platform_shared = {
    acr_id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/crshared"
    acr_login_server           = "crshared.azurecr.io"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.OperationalInsights/workspaces/log-shared"
  }
}
# END FIXTURE

run "external_default" {
  command = plan

  assert {
    condition     = azurerm_container_app_environment.this.internal_load_balancer_enabled == false && output.contract.ingress_mode == "external"
    error_message = "default (minimal profile) is an external, VNet-integrated environment."
  }
  assert {
    condition     = azurerm_container_app_environment.this.infrastructure_subnet_id == var.foundation_network.subnets["aca-infra"].id
    error_message = "environment must be injected into the aca-infra subnet."
  }
  assert {
    condition     = azurerm_container_app_environment.this.logs_destination == "azure-monitor"
    error_message = "logs go to Azure Monitor (diagnostic settings owned by observability)."
  }
  assert {
    condition     = length(azurerm_container_app_environment.this.workload_profile) == 2
    error_message = "Consumption + dedicated-d4 workload profiles."
  }
  assert {
    condition     = contains([for p in azurerm_container_app_environment.this.workload_profile : p.name if p.workload_profile_type == "D4" && p.maximum_count == 1 && p.minimum_count == 0], "dedicated-d4")
    error_message = "dedicated-d4 is D4 with min 0 / max 1."
  }
  assert {
    condition     = length(azurerm_private_dns_zone.env) == 0
    error_message = "no private zone for an external environment."
  }
  assert {
    condition     = output.contract.dedicated_profile_name == "dedicated-d4" && output.contract.static_ip_address == "10.41.2.200"
    error_message = "contract exposes profile and static IP."
  }
}

run "internal_enterprise" {
  command = plan
  variables {
    settings = { ingress_mode = "internal", dedicated_profile = { max_count = 3 } }
  }
  assert {
    condition     = azurerm_container_app_environment.this.internal_load_balancer_enabled == true && azurerm_container_app_environment.this.public_network_access == "Disabled"
    error_message = "internal environment uses the internal load balancer only."
  }
  assert {
    condition     = azurerm_private_dns_zone.env[0].name == "kindstone-12345678.swedencentral.azurecontainerapps.io"
    error_message = "private zone named after the default domain."
  }
  assert {
    condition     = azurerm_private_dns_a_record.wildcard[0].name == "*" && azurerm_private_dns_a_record.apex[0].name == "@" && azurerm_private_dns_a_record.wildcard[0].records == toset(["10.41.2.200"])
    error_message = "wildcard + apex A records to the static IP."
  }
  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.env) == 1
    error_message = "zone linked to the spoke VNet."
  }
}

run "dedicated_ceiling_validated" {
  command = plan
  variables {
    settings = { dedicated_profile = { max_count = 50 } }
  }
  expect_failures = [var.settings]
}
