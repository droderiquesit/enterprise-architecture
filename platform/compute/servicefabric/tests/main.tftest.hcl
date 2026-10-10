mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-sfmc-dev-sec"
    }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-sfmc-dev-sec/providers/Microsoft.ServiceFabric/managedClusters/eh-sfmc-sfmc-dev-sec"
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
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api", principal_id = "00000000-0000-0000-0001-000000000002", client_id = "00000000-0000-0000-0002-000000000002", name = "id-hello-inventory-api" }
      "obs-host-agent"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-host-agent", principal_id = "00000000-0000-0000-0001-000000000017", client_id = "00000000-0000-0000-0002-000000000017", name = "id-obs-host-agent" }
    }
  }
}
# END FIXTURE

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(azapi_resource.cluster) == 0 && length(azapi_resource.node_type) == 0 && length(azurerm_resource_group.this) == 0
    error_message = "Service Fabric is disabled by default (cost)."
  }
  assert {
    condition     = output.contract.enabled == false && output.contract.status == "disabled"
    error_message = "contract reports disabled."
  }
}

run "enabled_basic" {
  command = plan
  variables {
    settings = {
      enabled                           = true
      client_certificate_thumbprint     = "0123456789ABCDEF0123456789ABCDEF01234567"
      sf_resource_provider_principal_id = "11111111-1111-1111-1111-111111111111"
      byo_vnet                          = false
    }
  }
  assert {
    condition     = azapi_resource.cluster[0].body.sku.name == "Basic" && azapi_resource.node_type[0].body.properties.vmInstanceCount == 3
    error_message = "Basic SKU with the 3-node minimum."
  }
  assert {
    condition     = azapi_resource.node_type[0].body.properties.isPrimary == true && azapi_resource.node_type[0].body.properties.vmImageOffer == "WindowsServer"
    error_message = "Windows primary node type."
  }
  assert {
    condition     = azapi_resource.node_type[0].body.properties.applicationPorts.startPort == 20000 && azapi_resource.node_type[0].body.properties.ephemeralPorts.endPort == 65534
    error_message = "Port ranges are split into start/end."
  }
  assert {
    condition     = azapi_resource.cluster[0].body.properties.clients[0].isAdmin && azapi_resource.cluster[0].body.properties.subnetId == null && length(azurerm_role_assignment.sfrp_subnet) == 0
    error_message = "Admin client certificate; byo_vnet = false keeps the managed VNet although the SFRP principal is set."
  }
  assert {
    condition     = !can(azapi_resource.cluster[0].body.properties.adminPassword)
    error_message = "The admin password travels only in the write-only sensitive_body."
  }
}

run "datadog_identity_on_node_type" {
  command = plan
  variables {
    settings = {
      enabled                           = true
      client_certificate_thumbprint     = "0123456789ABCDEF0123456789ABCDEF01234567"
      sf_resource_provider_principal_id = "11111111-1111-1111-1111-111111111111"
      node_type                         = { tags = { service = "hello-inventory-api" } }
    }
  }
  assert {
    condition     = jsonencode(azapi_resource.node_type[0].body.properties.vmManagedIdentity.userAssignedIdentities) == jsonencode(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-host-agent"])
    error_message = "The obs-host-agent DSV-reader identity (foundation-identity contract) is attached through the node type API."
  }
  assert {
    condition     = !can(azapi_resource.node_type[0].body.properties.vmApplications)
    error_message = "vmApplications is obs-hosts-owned: this root never sends it (ignore_body_changes keeps the remote value)."
  }
  assert {
    condition     = azurerm_role_assignment.sfrp_dd_identity[0].role_definition_name == "Managed Identity Operator" && azurerm_role_assignment.sfrp_dd_identity[0].principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "SFRP gets Managed Identity Operator on the DSV-reader identity."
  }
  assert {
    condition     = azapi_resource.node_type[0].tags["datadog:enabled"] == "true" && azapi_resource.node_type[0].tags["service"] == "hello-inventory-api"
    error_message = "Node type tagged datadog:enabled + operator tags."
  }
  assert {
    condition     = output.contract.node_types["nt1"].datadog_enabled && output.contract.node_types["nt1"].os_type == "windows" && output.contract.datadog.enabled
    error_message = "Contract publishes the node types for obs-hosts."
  }
  assert {
    condition     = length(azurerm_role_assignment.sfrp_subnet) == 1 && azapi_resource.cluster[0].body.properties.subnetId == var.foundation_network.subnets["sfmc"].id
    error_message = "byo_vnet unset: the SFRP principal keeps the pre-4.1 BYO VNet behaviour."
  }
}

run "datadog_disabled" {
  command = plan
  variables {
    settings = {
      enabled                       = true
      client_certificate_thumbprint = "0123456789ABCDEF0123456789ABCDEF01234567"
      datadog                       = { enabled = false }
    }
  }
  assert {
    condition     = azapi_resource.node_type[0].body.properties.vmManagedIdentity == null && length(azurerm_role_assignment.sfrp_dd_identity) == 0 && !output.contract.node_types["nt1"].datadog_enabled
    error_message = "datadog.enabled = false: no identity, no role, node type not enrolled."
  }
}

run "datadog_needs_sfrp_principal" {
  command = plan
  variables {
    settings = {
      enabled                       = true
      client_certificate_thumbprint = "0123456789ABCDEF0123456789ABCDEF01234567"
    }
  }
  expect_failures = [var.settings]
}

run "enabled_requires_auth" {
  command = plan
  variables {
    settings = { enabled = true, datadog = { enabled = false } }
  }
  expect_failures = [var.settings]
}

run "basic_minimum_nodes" {
  command = plan
  variables {
    settings = { node_type = { instance_count = 1 } }
  }
  expect_failures = [var.settings]
}
