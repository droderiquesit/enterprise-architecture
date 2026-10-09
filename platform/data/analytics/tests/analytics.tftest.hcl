# Plan-only tests with mocked providers: no Azure credentials are needed.
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/ehstdataanldevabcdeb"
      primary_blob_endpoint = "https://ehstdataanldevabcdeb.blob.core.windows.net/"
      primary_dfs_endpoint  = "https://ehstdataanldevabcded.dfs.core.windows.net/"
    }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/acct/blobServices/default/containers/adapter" }
  }
  mock_resource "azurerm_kusto_cluster" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Kusto/clusters/ehdataanldevabcde"
      uri                = "https://ehdataanldevabcde.swedencentral.kusto.windows.net"
      data_ingestion_uri = "https://ingest-ehdataanldevabcde.swedencentral.kusto.windows.net"
    }
  }
  mock_resource "azurerm_kusto_database" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Kusto/clusters/c/databases/adapter" }
  }
  mock_resource "azurerm_search_service" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Search/searchServices/eh-data-anl-dev-abcde" }
  }
  mock_resource "azurerm_synapse_workspace" {
    defaults = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Synapse/workspaces/eh-data-anl-dev-abcde"
      connectivity_endpoints = { sql = "eh-data-anl-dev-abcde.sql.azuresynapse.net" }
    }
  }
  mock_resource "azurerm_private_endpoint" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/pe" }
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

run "defaults_storage_only" {
  command = plan
  variables {
    settings = {}
  }
  assert {
    condition     = azurerm_storage_account.blob[0].shared_access_key_enabled == false && azurerm_storage_account.blob[0].public_network_access == "Disabled"
    error_message = "Blob: shared key and public access disabled."
  }
  assert {
    condition     = azurerm_storage_account.adls[0].is_hns_enabled && azurerm_storage_account.adls[0].shared_access_key_enabled == false && azurerm_storage_account.adls[0].public_network_access == "Disabled"
    error_message = "ADLS Gen2 with HNS, private, Entra-only."
  }
  assert {
    condition     = azurerm_role_assignment.blob_adapter[0].role_definition_name == "Storage Blob Data Contributor" && azurerm_role_assignment.adls_adapter[0].principal_id == "aaaaaaaa-0000-0000-0000-000000000004"
    error_message = "hello-dbadapter gets Storage Blob Data Contributor on its containers."
  }
  assert {
    condition     = length(module.pe_blob) == 1 && length(module.pe_adls) == 2
    error_message = "Private endpoints: blob (blob account), dfs + blob (ADLS)."
  }
  assert {
    condition     = length(azurerm_kusto_cluster.this) == 0 && length(azurerm_search_service.this) == 0 && length(azurerm_synapse_workspace.this) == 0
    error_message = "ADX, AI Search and Synapse are off by default."
  }
  assert {
    condition     = output.contract.data_explorer == null && output.contract.blob.enabled == true
    error_message = "Contract reports toggles."
  }
}

run "all_enabled" {
  command = plan
  variables {
    settings = {
      data_explorer = { enabled = true }
      search        = { enabled = true }
      synapse       = { enabled = true, entra_admin = { login = "eh-synapse-admins", object_id = "cccccccc-0000-0000-0000-000000000007" } }
    }
  }
  assert {
    condition     = azurerm_kusto_cluster.this[0].sku[0].name == "Dev(No SLA)_Standard_E2a_v4" && azurerm_kusto_cluster.this[0].auto_stop_enabled && azurerm_kusto_cluster.this[0].public_network_access_enabled == false
    error_message = "ADX dev SKU, auto-stop, private."
  }
  assert {
    condition     = azurerm_kusto_database.adapter[0].soft_delete_period == "P7D" && length(azurerm_kusto_database_principal_assignment.adapter) == 2
    error_message = "ADX db adapter with short retention and adapter principal assignments."
  }
  assert {
    condition     = azurerm_search_service.this[0].sku == "basic" && azurerm_search_service.this[0].local_authentication_enabled == false && azurerm_search_service.this[0].public_network_access_enabled == false && length(module.pe_search) == 1
    error_message = "AI Search basic, keys disabled, private endpoint."
  }
  assert {
    condition     = azurerm_synapse_workspace.this[0].azuread_authentication_only && azurerm_synapse_workspace.this[0].public_network_access_enabled == false
    error_message = "Synapse Entra-only and private."
  }
}

run "rejects_free_search_with_private_endpoints" {
  command = plan
  variables {
    settings = { search = { enabled = true, sku = "free" } }
  }
  expect_failures = [var.settings]
}
