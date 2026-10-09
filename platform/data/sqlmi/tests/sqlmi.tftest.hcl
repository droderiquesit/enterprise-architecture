# Plan-only tests with mocked providers: no Azure credentials are needed.
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-data-sqlmi-dev-sec" }
  }
  mock_resource "azurerm_mssql_managed_instance" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Sql/managedInstances/eh-sqlmi-data-sqlmi-dev-sec"
      fqdn = "eh-sqlmi-data-sqlmi-dev-sec.abc123.database.windows.net"
    }
  }
  mock_resource "azurerm_mssql_managed_database" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Sql/managedInstances/mi/databases/adapter" }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Sql/managedInstances/eh-sqlmi-data-sqlmi-dev-sec"
      output = { properties = { fullyQualifiedDomainName = "eh-sqlmi-data-sqlmi-dev-sec.abc123.database.windows.net" } }
    }
  }
}

variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "11111111-1111-1111-1111-111111111111"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  foundation_network = {
    resource_group_name = "eh-rg-net-dev-sec"
    location            = "swedencentral"
    spoke_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec"
    subnets = {
      "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-private-endpoints", name = "snet-private-endpoints", address_prefix = "10.41.4.0/24" }
      "compute"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-compute", name = "snet-compute", address_prefix = "10.41.0.0/24" }
      "postgres"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-postgres", name = "snet-postgres", address_prefix = "10.41.5.0/28" }
      "mysql"             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-mysql", name = "snet-mysql", address_prefix = "10.41.5.16/28" }
      "sqlmi"             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-sqlmi", name = "snet-sqlmi", address_prefix = "10.41.6.0/27" }
      "cassandra-mi"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/virtualNetworks/eh-vnet-spoke-dev-sec/subnets/snet-cassandra-mi", name = "snet-cassandra-mi", address_prefix = "10.41.7.0/24" }
    }
    private_dns_zones = {
      blob             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net", name = "privatelink.blob.core.windows.net" }
      dfs              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net", name = "privatelink.dfs.core.windows.net" }
      table            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net", name = "privatelink.table.core.windows.net" }
      sql              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net", name = "privatelink.database.windows.net" }
      postgres         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com", name = "privatelink.postgres.database.azure.com" }
      mysql            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.mysql.database.azure.com", name = "privatelink.mysql.database.azure.com" }
      cosmos_sql       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com", name = "privatelink.documents.azure.com" }
      cosmos_mongo     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.mongo.cosmos.azure.com", name = "privatelink.mongo.cosmos.azure.com" }
      cosmos_cassandra = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.cassandra.cosmos.azure.com", name = "privatelink.cassandra.cosmos.azure.com" }
      cosmos_gremlin   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.gremlin.cosmos.azure.com", name = "privatelink.gremlin.cosmos.azure.com" }
      cosmos_table     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.table.cosmos.azure.com", name = "privatelink.table.cosmos.azure.com" }
      documentdb       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.mongocluster.cosmos.azure.com", name = "privatelink.mongocluster.cosmos.azure.com" }
      redis            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net", name = "privatelink.redis.azure.net" }
      search           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net", name = "privatelink.search.windows.net" }
      kusto            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.kusto.windows.net", name = "privatelink.swedencentral.kusto.windows.net" }
      vault            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-net-dev-sec/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net", name = "privatelink.vaultcore.azure.net" }
    }
  }
  foundation_identity = {
    key_vault_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.KeyVault/vaults/eh-kv-id-dev-abcde"
    key_vault_uri = "https://eh-kv-id-dev-abcde.vault.azure.net/"
    identities = {
      "hello-orders-api"    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-orders-api", principal_id = "aaaaaaaa-0000-0000-0000-000000000001", client_id = "bbbbbbbb-0000-0000-0000-000000000001", name = "hello-orders-api" }
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-inventory-api", principal_id = "aaaaaaaa-0000-0000-0000-000000000002", client_id = "bbbbbbbb-0000-0000-0000-000000000002", name = "hello-inventory-api" }
      "hello-catalog-api"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-catalog-api", principal_id = "aaaaaaaa-0000-0000-0000-000000000003", client_id = "bbbbbbbb-0000-0000-0000-000000000003", name = "hello-catalog-api" }
      "hello-dbadapter"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-dbadapter", principal_id = "aaaaaaaa-0000-0000-0000-000000000004", client_id = "bbbbbbbb-0000-0000-0000-000000000004", name = "hello-dbadapter" }
      "hello-worker"        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-worker", principal_id = "aaaaaaaa-0000-0000-0000-000000000005", client_id = "bbbbbbbb-0000-0000-0000-000000000005", name = "hello-worker" }
      "hello-durable"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-durable", principal_id = "aaaaaaaa-0000-0000-0000-000000000006", client_id = "bbbbbbbb-0000-0000-0000-000000000006", name = "hello-durable" }
      "hello-functions"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-functions", principal_id = "aaaaaaaa-0000-0000-0000-000000000007", client_id = "bbbbbbbb-0000-0000-0000-000000000007", name = "hello-functions" }
      "hello-jobs"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/hello-jobs", principal_id = "aaaaaaaa-0000-0000-0000-000000000008", client_id = "bbbbbbbb-0000-0000-0000-000000000008", name = "hello-jobs" }
      "obs-dbm"             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-id-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/obs-dbm", principal_id = "aaaaaaaa-0000-0000-0000-000000000009", client_id = "bbbbbbbb-0000-0000-0000-000000000009", name = "obs-dbm" }
    }
  }
}

run "disabled_by_default" {
  command = plan

  variables {
    settings = {}
  }

  assert {
    condition     = length(azurerm_mssql_managed_instance.this) == 0 && length(azapi_resource.free) == 0 && length(azurerm_resource_group.this) == 0
    error_message = "SQL MI must be disabled by default."
  }
  assert {
    condition     = output.contract.enabled == false && output.contract.server == null
    error_message = "Contract reports disabled."
  }
}

run "enabled_paid" {
  command = plan
  variables {
    settings = {
      enabled     = true
      entra_admin = { login = "eh-sqlmi-admins", object_id = "cccccccc-0000-0000-0000-000000000004" }
    }
  }
  assert {
    condition     = azurerm_mssql_managed_instance.this[0].vcores == 4 && azurerm_mssql_managed_instance.this[0].sku_name == "GP_Gen5" && azurerm_mssql_managed_instance.this[0].storage_size_in_gb == 32
    error_message = "General Purpose 4 vCore, 32 GB."
  }
  assert {
    condition     = azurerm_mssql_managed_instance.this[0].public_data_endpoint_enabled == false && azurerm_mssql_managed_instance.this[0].azure_active_directory_administrator[0].azuread_authentication_only_enabled
    error_message = "No public data endpoint; Entra-only."
  }
  assert {
    condition     = length(azurerm_mssql_managed_instance_start_stop_schedule.this[0].schedule) == 5
    error_message = "Weekday start/stop schedule."
  }
  assert {
    condition     = output.contract.dbm.deployment_type == "managed_instance" && output.contract.databases.adapter.owner_identity_name == "hello-dbadapter"
    error_message = "Contract DBM + adapter db."
  }
}

run "enabled_free_offer" {
  command = plan
  variables {
    settings = {
      enabled     = true
      free_offer  = true
      entra_admin = { login = "eh-sqlmi-admins", object_id = "cccccccc-0000-0000-0000-000000000004" }
    }
  }
  assert {
    condition     = length(azurerm_mssql_managed_instance.this) == 0 && azapi_resource.free[0].body.properties.pricingModel == "Freemium" && azapi_resource.free[0].body.properties.publicDataEndpointEnabled == false
    error_message = "Free offer path uses AzAPI with pricingModel Freemium."
  }
  assert {
    condition     = output.contract.server.pricing_model == "Freemium"
    error_message = "Contract reports Freemium."
  }
}

run "requires_admin_when_enabled" {
  command = plan
  variables {
    settings = { enabled = true }
  }
  expect_failures = [var.settings]
}
