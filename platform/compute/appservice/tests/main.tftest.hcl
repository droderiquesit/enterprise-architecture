mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-appsvc-dev-sec/providers/Microsoft.Web/serverFarms/eh-asp-appsvc-dev-sec"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-appsvc-dev-sec/providers/Microsoft.Storage/storageAccounts/ehstappsvcdev12345la"
      primary_blob_endpoint = "https://ehstappsvcdev12345la.blob.core.windows.net/"
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
    subnets = {
      "compute" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-compute", name = "snet-compute", address_prefix = "10.41.0.0/24" }
      "aks-nodes" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aks-nodes", name = "snet-aks-nodes", address_prefix = "10.41.1.0/24" }
      "aca-infra" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca-infra", name = "snet-aca-infra", address_prefix = "10.41.2.0/24" }
      "appsvc-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration", name = "snet-appsvc-integration", address_prefix = "10.41.3.0/24" }
      "flex-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration", name = "snet-flex-integration", address_prefix = "10.41.4.0/24" }
      "aci" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aci", name = "snet-aci", address_prefix = "10.41.5.0/24" }
      "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-private-endpoints", name = "snet-private-endpoints", address_prefix = "10.41.6.0/24" }
      "postgres" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-postgres", name = "snet-postgres", address_prefix = "10.41.7.0/24" }
      "mysql" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-mysql", name = "snet-mysql", address_prefix = "10.41.8.0/24" }
      "sqlmi" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sqlmi", name = "snet-sqlmi", address_prefix = "10.41.9.0/24" }
      "cassandra-mi" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-cassandra-mi", name = "snet-cassandra-mi", address_prefix = "10.41.10.0/24" }
      "batch" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-batch", name = "snet-batch", address_prefix = "10.41.11.0/24" }
      "deploy-agents" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-deploy-agents", name = "snet-deploy-agents", address_prefix = "10.41.12.0/24" }
      "observability" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-observability", name = "snet-observability", address_prefix = "10.41.13.0/24" }
      "sfmc" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sfmc", name = "snet-sfmc", address_prefix = "10.41.14.0/24" }
      "aro-master" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-master", name = "snet-aro-master", address_prefix = "10.41.15.0/24" }
      "aro-worker" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-worker", name = "snet-aro-worker", address_prefix = "10.41.16.0/24" }
    }
    private_dns_zones = {
      blob = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net", name = "privatelink.blob.core.windows.net" }
      file = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net", name = "privatelink.file.core.windows.net" }
      queue = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net", name = "privatelink.queue.core.windows.net" }
      table = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net", name = "privatelink.table.core.windows.net" }
      dfs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net", name = "privatelink.dfs.core.windows.net" }
      vault = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net", name = "privatelink.vaultcore.azure.net" }
      servicebus = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net", name = "privatelink.servicebus.windows.net" }
      acr = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io", name = "privatelink.azurecr.io" }
      sites = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net", name = "privatelink.azurewebsites.net" }
      aca = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.azurecontainerapps.io", name = "privatelink.swedencentral.azurecontainerapps.io" }
    }
  }
  foundation_identity = {
    identities = {
      "hello-bff" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-bff", principal_id = "00000000-0000-0000-0001-000000000000", client_id = "00000000-0000-0000-0002-000000000000", name = "id-hello-bff" }
      "hello-orders-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-orders-api", principal_id = "00000000-0000-0000-0001-000000000001", client_id = "00000000-0000-0000-0002-000000000001", name = "id-hello-orders-api" }
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api", principal_id = "00000000-0000-0000-0001-000000000002", client_id = "00000000-0000-0000-0002-000000000002", name = "id-hello-inventory-api" }
      "hello-catalog-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api", principal_id = "00000000-0000-0000-0001-000000000003", client_id = "00000000-0000-0000-0002-000000000003", name = "id-hello-catalog-api" }
      "hello-dbadapter" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter", principal_id = "00000000-0000-0000-0001-000000000004", client_id = "00000000-0000-0000-0002-000000000004", name = "id-hello-dbadapter" }
      "hello-worker" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker", principal_id = "00000000-0000-0000-0001-000000000005", client_id = "00000000-0000-0000-0002-000000000005", name = "id-hello-worker" }
      "hello-durable" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-durable", principal_id = "00000000-0000-0000-0001-000000000006", client_id = "00000000-0000-0000-0002-000000000006", name = "id-hello-durable" }
      "hello-functions" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-functions", principal_id = "00000000-0000-0000-0001-000000000007", client_id = "00000000-0000-0000-0002-000000000007", name = "id-hello-functions" }
      "hello-jobs" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs", principal_id = "00000000-0000-0000-0001-000000000008", client_id = "00000000-0000-0000-0002-000000000008", name = "id-hello-jobs" }
      "hello-partner-sim" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-partner-sim", principal_id = "00000000-0000-0000-0001-000000000009", client_id = "00000000-0000-0000-0002-000000000009", name = "id-hello-partner-sim" }
      "hello-traffic" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-traffic", principal_id = "00000000-0000-0000-0001-000000000010", client_id = "00000000-0000-0000-0002-000000000010", name = "id-hello-traffic" }
      "hello-frontend" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-frontend", principal_id = "00000000-0000-0000-0001-000000000011", client_id = "00000000-0000-0000-0002-000000000011", name = "id-hello-frontend" }
      "obs-collector" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector", principal_id = "00000000-0000-0000-0001-000000000012", client_id = "00000000-0000-0000-0002-000000000012", name = "id-obs-collector" }
      "obs-dbm" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-dbm", principal_id = "00000000-0000-0000-0001-000000000013", client_id = "00000000-0000-0000-0002-000000000013", name = "id-obs-dbm" }
      "aks-control-plane" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-control-plane", principal_id = "00000000-0000-0000-0001-000000000014", client_id = "00000000-0000-0000-0002-000000000014", name = "id-aks-control-plane" }
      "aks-kubelet" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-kubelet", principal_id = "00000000-0000-0000-0001-000000000015", client_id = "00000000-0000-0000-0002-000000000015", name = "id-aks-kubelet" }
      "deploy-agent" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-deploy-agent", principal_id = "00000000-0000-0000-0001-000000000016", client_id = "00000000-0000-0000-0002-000000000016", name = "id-deploy-agent" }
    }
  }
}
# END FIXTURE

run "defaults" {
  command = plan

  assert {
    condition     = toset(keys(azurerm_service_plan.this)) == toset(["linux", "windows"])
    error_message = "Linux + Windows code plans by default; Windows container plan off."
  }
  assert {
    condition     = azurerm_service_plan.this["linux"].sku_name == "P0v3" && azurerm_service_plan.this["linux"].os_type == "Linux"
    error_message = "Linux plan P0v3."
  }
  assert {
    condition     = azurerm_service_plan.this["windows"].sku_name == "P0v3" && azurerm_service_plan.this["windows"].os_type == "Windows"
    error_message = "Windows plan P0v3."
  }
  assert {
    condition     = length(azurerm_service_plan.logicapps) == 0 && length(azurerm_storage_account.logicapps) == 0
    error_message = "Logic Apps Standard is opt-in."
  }
  assert {
    condition     = output.contract.integration_subnet_id == var.foundation_network.subnets["appsvc-integration"].id && output.contract.functions_dedicated_plan == "linux"
    error_message = "contract exposes integration subnet and dedicated functions plan."
  }
}

run "all_plans" {
  command = plan
  variables {
    settings = {
      windows_container_plan = { enabled = true }
      logicapps_plan         = { enabled = true }
    }
  }
  assert {
    condition     = azurerm_service_plan.this["windows_container"].os_type == "WindowsContainer" && azurerm_service_plan.this["windows_container"].sku_name == "P1v3"
    error_message = "Windows container plan P1v3."
  }
  assert {
    condition     = azurerm_service_plan.logicapps[0].sku_name == "WS1" && azurerm_service_plan.logicapps[0].maximum_elastic_worker_count == 3
    error_message = "Logic Apps WS1 with elastic ceiling."
  }
  assert {
    condition     = azurerm_storage_account.logicapps[0].public_network_access == "Disabled" && length(module.logicapps_storage_pe) == 4
    error_message = "Logic Apps runtime storage is private (blob/queue/table/file endpoints)."
  }
  assert {
    condition     = azurerm_storage_account.logicapps[0].min_tls_version == "TLS1_2" && azurerm_storage_account.logicapps[0].allow_nested_items_to_be_public == false
    error_message = "storage hardening."
  }
}

run "windows_container_needs_premium" {
  command = plan
  variables {
    settings = { windows_container_plan = { enabled = true, sku = "S1" } }
  }
  expect_failures = [var.settings]
}
