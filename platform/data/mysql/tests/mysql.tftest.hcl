# Plan-only tests with mocked providers: no Azure credentials are needed.
# hashicorp/random is not mocked: mock providers do not support ephemeral resources; it runs locally without credentials.
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_mysql_flexible_server" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/eh-data-mysql-dev-abcde"
      fqdn = "eh-data-mysql-dev-abcde.mysql.database.azure.com"
    }
  }
  mock_resource "azurerm_mysql_flexible_database" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/s/databases/adapter" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/server" }
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
  settings = {
    entra_admin = { login = "eh-mysql-admins", object_id = "cccccccc-0000-0000-0000-000000000003" }
  }
}

run "defaults_vnet" {
  command = plan

  assert {
    condition     = azurerm_mysql_flexible_server.this.public_network_access == "Disabled" && azurerm_mysql_flexible_server.this.delegated_subnet_id != null && length(module.private_endpoint) == 0
    error_message = "VNet-injected, public access disabled."
  }
  assert {
    condition     = azurerm_mysql_flexible_server.this.version == "8.4" && azurerm_mysql_flexible_server.this.sku_name == "B_Standard_B1ms" && azurerm_mysql_flexible_server.this.backup_retention_days == 7
    error_message = "MySQL 8.4 B1ms, 7-day backups."
  }
  assert {
    condition     = azurerm_mysql_flexible_server_configuration.this["performance_schema"].value == "ON"
    error_message = "performance_schema must be ON for Datadog DBM."
  }
  assert {
    condition     = azurerm_mysql_flexible_server_active_directory_administrator.this.login == "eh-mysql-admins"
    error_message = "Entra admin configured."
  }
  assert {
    condition     = output.contract.dbm.auth_mode == "native-password" && output.contract.dbm.password_secret_id == "https://eh-kv-id-dev-abcde.vault.azure.net/secrets/dbm-mysql-password"
    error_message = "DBM uses a native user whose password lives in Key Vault (reference only)."
  }
  assert {
    condition     = output.contract.databases.adapter.owner_identity_name == "hello-dbadapter" && output.contract.databases.adapter.grants[0].client_id == "bbbbbbbb-0000-0000-0000-000000000004"
    error_message = "db adapter owned by hello-dbadapter."
  }
}

run "private_endpoint_mode" {
  command = plan
  variables {
    settings = {
      entra_admin  = { login = "eh-mysql-admins", object_id = "cccccccc-0000-0000-0000-000000000003" }
      network_mode = "private-endpoint"
    }
  }
  assert {
    condition     = azurerm_mysql_flexible_server.this.delegated_subnet_id == null && length(module.private_endpoint) == 1 && output.contract.private_endpoint.enabled
    error_message = "PE mode creates the mysqlServer private endpoint."
  }
}
