mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_orchestrated_virtual_machine_scale_set" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-vmss-dev-sec/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-vmss-dev-sec-flex"
    }
  }
  mock_resource "azurerm_linux_virtual_machine_scale_set" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-vmss-dev-sec/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-vmss-dev-sec-uni"
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

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_orchestrated_virtual_machine_scale_set.flexible[0].instances == 1 && contains(azurerm_orchestrated_virtual_machine_scale_set.flexible[0].identity[0].identity_ids, var.foundation_identity.identities["hello-worker"].id)
    error_message = "Flexible VMSS: 1 instance running as hello-worker."
  }
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.uniform[0].upgrade_mode == "Manual" && contains(azurerm_linux_virtual_machine_scale_set.uniform[0].identity[0].identity_ids, var.foundation_identity.identities["hello-dbadapter"].id)
    error_message = "Uniform VMSS: Manual upgrades, hello-dbadapter identity."
  }
  assert {
    condition     = length(azurerm_orchestrated_virtual_machine_scale_set.flexible[0].network_interface[0].ip_configuration[0].public_ip_address) == 0 && length(azurerm_linux_virtual_machine_scale_set.uniform[0].network_interface[0].ip_configuration[0].public_ip_address) == 0
    error_message = "no instance public IPs."
  }
  assert {
    condition     = azurerm_monitor_autoscale_setting.this["flexible"].profile[0].capacity[0].maximum == 3 && azurerm_monitor_autoscale_setting.this["uniform"].profile[0].capacity[0].maximum == 2
    error_message = "autoscale ceilings respected (3 flexible / 2 uniform)."
  }
  assert {
    condition     = alltrue([for a in azurerm_monitor_autoscale_setting.this : a.profile[0].capacity[0].minimum <= a.profile[0].capacity[0].default && a.profile[0].capacity[0].default <= a.profile[0].capacity[0].maximum])
    error_message = "min <= default <= max."
  }
  assert {
    condition     = output.contract.scale_sets["flexible"].orchestration_mode == "Flexible" && output.contract.scale_sets["uniform"].orchestration_mode == "Uniform"
    error_message = "contract exposes orchestration modes."
  }
}

run "ceiling_validation" {
  command = plan
  variables {
    settings = { flexible = { max_instances = 50 } }
  }
  expect_failures = [var.settings]
}

run "custom_ceiling" {
  command = plan
  variables {
    settings = { flexible = { instances = 2, min_instances = 1, max_instances = 5 }, uniform = { enabled = false } }
  }
  assert {
    condition     = azurerm_monitor_autoscale_setting.this["flexible"].profile[0].capacity[0].maximum == 5 && length(azurerm_linux_virtual_machine_scale_set.uniform) == 0
    error_message = "custom ceiling and toggle."
  }
}
