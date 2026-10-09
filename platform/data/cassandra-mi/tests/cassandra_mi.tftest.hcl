# Plan-only tests with mocked providers: no Azure credentials are needed.
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_cosmosdb_cassandra_cluster" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DocumentDB/cassandraClusters/eh-mi-cass-data-cassmi-dev-sec" }
  }
  mock_resource "azurerm_cosmosdb_cassandra_datacenter" {
    defaults = { seed_node_ip_addresses = ["10.41.7.4", "10.41.7.5", "10.41.7.6"] }
  }
  mock_resource "azurerm_key_vault_secret" {
    defaults = { versionless_id = "https://eh-kv-id-dev-abcde.vault.azure.net/secrets/cassandra-mi-admin-password" }
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
    condition     = length(azurerm_cosmosdb_cassandra_cluster.this) == 0 && output.contract.enabled == false && output.contract.cluster == null
    error_message = "Cassandra MI is disabled by default."
  }
}

run "enabled" {
  command = plan
  variables {
    settings = {
      enabled                              = true
      cosmosdb_service_principal_object_id = "eeeeeeee-0000-0000-0000-000000000001"
    }
  }
  assert {
    condition     = azurerm_cosmosdb_cassandra_datacenter.dc1[0].node_count == 3 && azurerm_cosmosdb_cassandra_datacenter.dc1[0].sku_name == "Standard_D8s_v4"
    error_message = "3 x Standard_D8s_v4 nodes."
  }
  assert {
    condition     = azurerm_role_assignment.cosmosdb_network[0].role_definition_name == "Network Contributor" && endswith(azurerm_role_assignment.cosmosdb_network[0].scope, "/subnets/snet-cassandra-mi")
    error_message = "Cosmos DB SP gets Network Contributor on the delegated subnet."
  }
  assert {
    condition     = startswith(output.contract.cluster.admin_password_secret_id, "https://")
    error_message = "Only secret IDs in the contract."
  }
}

run "requires_sp_when_enabled" {
  command = plan
  variables {
    settings = { enabled = true }
  }
  expect_failures = [var.settings]
}
