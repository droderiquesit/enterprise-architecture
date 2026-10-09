mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_network_interface" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Network/networkInterfaces/nic"
      private_ip_address = "10.41.0.10"
    }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Compute/virtualMachines/vm"
    }
  }
  mock_resource "azurerm_dedicated_host_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Compute/hostGroups/dhg"
    }
  }
  mock_resource "azurerm_dedicated_host" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Compute/hostGroups/dhg/hosts/host0"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.OperationalInsights/workspaces/log"
    }
  }
  mock_resource "azurerm_application_insights" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Insights/components/appi"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.KeyVault/vaults/kv"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Storage/storageAccounts/ehstspecdevabcdeml"
    }
  }
  mock_resource "azurerm_automation_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.Automation/automationAccounts/aa"
    }
  }
  mock_resource "azurerm_machine_learning_compute_cluster" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.MachineLearningServices/workspaces/mlw/computes/cpu-cluster"
    }
  }
  mock_resource "azurerm_machine_learning_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-spec-dev-sec/providers/Microsoft.MachineLearningServices/workspaces/mlw"
    }
  }
}

mock_provider "random" {}

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
    private_dns_zones = {
      blob       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net", name = "privatelink.blob.core.windows.net" }
      file       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net", name = "privatelink.file.core.windows.net" }
      queue      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net", name = "privatelink.queue.core.windows.net" }
      table      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net", name = "privatelink.table.core.windows.net" }
      dfs        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net", name = "privatelink.dfs.core.windows.net" }
      vault      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net", name = "privatelink.vaultcore.azure.net" }
      servicebus = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net", name = "privatelink.servicebus.windows.net" }
      acr        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io", name = "privatelink.azurecr.io" }
      sites      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net", name = "privatelink.azurewebsites.net" }
      aca        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.azurecontainerapps.io", name = "privatelink.swedencentral.azurecontainerapps.io" }
    }
  }
  foundation_identity = {
    identities = {
      "hello-bff"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-bff", principal_id = "00000000-0000-0000-0001-000000000000", client_id = "00000000-0000-0000-0002-000000000000", name = "id-hello-bff" }
      "hello-orders-api"    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-orders-api", principal_id = "00000000-0000-0000-0001-000000000001", client_id = "00000000-0000-0000-0002-000000000001", name = "id-hello-orders-api" }
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api", principal_id = "00000000-0000-0000-0001-000000000002", client_id = "00000000-0000-0000-0002-000000000002", name = "id-hello-inventory-api" }
      "hello-catalog-api"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api", principal_id = "00000000-0000-0000-0001-000000000003", client_id = "00000000-0000-0000-0002-000000000003", name = "id-hello-catalog-api" }
      "hello-dbadapter"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter", principal_id = "00000000-0000-0000-0001-000000000004", client_id = "00000000-0000-0000-0002-000000000004", name = "id-hello-dbadapter" }
      "hello-worker"        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker", principal_id = "00000000-0000-0000-0001-000000000005", client_id = "00000000-0000-0000-0002-000000000005", name = "id-hello-worker" }
      "hello-durable"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-durable", principal_id = "00000000-0000-0000-0001-000000000006", client_id = "00000000-0000-0000-0002-000000000006", name = "id-hello-durable" }
      "hello-functions"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-functions", principal_id = "00000000-0000-0000-0001-000000000007", client_id = "00000000-0000-0000-0002-000000000007", name = "id-hello-functions" }
      "hello-jobs"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs", principal_id = "00000000-0000-0000-0001-000000000008", client_id = "00000000-0000-0000-0002-000000000008", name = "id-hello-jobs" }
      "hello-partner-sim"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-partner-sim", principal_id = "00000000-0000-0000-0001-000000000009", client_id = "00000000-0000-0000-0002-000000000009", name = "id-hello-partner-sim" }
      "hello-traffic"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-traffic", principal_id = "00000000-0000-0000-0001-000000000010", client_id = "00000000-0000-0000-0002-000000000010", name = "id-hello-traffic" }
      "hello-frontend"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-frontend", principal_id = "00000000-0000-0000-0001-000000000011", client_id = "00000000-0000-0000-0002-000000000011", name = "id-hello-frontend" }
      "obs-collector"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector", principal_id = "00000000-0000-0000-0001-000000000012", client_id = "00000000-0000-0000-0002-000000000012", name = "id-obs-collector" }
      "obs-dbm"             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-dbm", principal_id = "00000000-0000-0000-0001-000000000013", client_id = "00000000-0000-0000-0002-000000000013", name = "id-obs-dbm" }
      "aks-control-plane"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-control-plane", principal_id = "00000000-0000-0000-0001-000000000014", client_id = "00000000-0000-0000-0002-000000000014", name = "id-aks-control-plane" }
      "aks-kubelet"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-kubelet", principal_id = "00000000-0000-0000-0001-000000000015", client_id = "00000000-0000-0000-0002-000000000015", name = "id-aks-kubelet" }
      "deploy-agent"        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-deploy-agent", principal_id = "00000000-0000-0000-0001-000000000016", client_id = "00000000-0000-0000-0002-000000000016", name = "id-deploy-agent" }
    }
  }
}
# END FIXTURE

run "all_off_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_resource_group.this) == 0 && length(azurerm_linux_virtual_machine.this) == 0 && length(azurerm_machine_learning_workspace.this) == 0 && length(azurerm_automation_account.this) == 0
    error_message = "every specialized capability is off by default."
  }
  assert {
    condition     = output.contract.capabilities.avs == "blocked" && output.contract.capabilities.confidential_vm == "disabled"
    error_message = "contract reports status vocabulary."
  }
}

run "everything_on" {
  command = plan
  variables {
    settings = {
      confidential_vm = { enabled = true }
      dedicated_host  = { enabled = true }
      gpu_vm          = { enabled = true }
      automation      = { enabled = true }
      ml              = { enabled = true }
    }
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this["cvm"].os_disk[0].security_encryption_type == "VMGuestStateOnly" && azurerm_linux_virtual_machine.this["cvm"].size == "Standard_DC2as_v5" && azurerm_linux_virtual_machine.this["cvm"].vtpm_enabled
    error_message = "confidential VM: DCasv5 with VM guest state encryption + vTPM."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this["dh"].dedicated_host_id != null
    error_message = "dedicated-host VM is placed on the host."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this["gpu"].size == "Standard_NC4as_T4_v3"
    error_message = "GPU VM size."
  }
  assert {
    condition     = alltrue([for n in azurerm_network_interface.this : n.ip_configuration[0].public_ip_address_id == null])
    error_message = "no public IPs on specialized VMs."
  }
  assert {
    condition     = azurerm_automation_account.this[0].local_authentication_enabled == false && azurerm_automation_schedule.health_probe[0].frequency == "Hour"
    error_message = "Automation: Entra only + placeholder hourly schedule."
  }
  assert {
    condition     = azurerm_machine_learning_compute_cluster.cpu[0].scale_settings[0].min_node_count == 0 && azurerm_machine_learning_compute_cluster.cpu[0].scale_settings[0].max_node_count == 1
    error_message = "ML compute cluster scales to zero with ceiling 1."
  }
  assert {
    condition     = azurerm_machine_learning_workspace.this[0].application_insights_id != null && azurerm_machine_learning_workspace.this[0].key_vault_id != null
    error_message = "AML workspace has its required dependencies."
  }
}
