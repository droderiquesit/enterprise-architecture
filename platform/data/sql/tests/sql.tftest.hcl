# Plan-only tests with mocked providers: no Azure credentials are needed.
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_mssql_server" {
    defaults = {
      id                          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-data-sql-dev-sec/providers/Microsoft.Sql/servers/eh-data-sql-dev-abcde"
      fully_qualified_domain_name = "eh-data-sql-dev-abcde.database.windows.net"
    }
  }
  mock_resource "azurerm_mssql_elasticpool" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-data-sql-dev-sec/providers/Microsoft.Sql/servers/eh-data-sql-dev-abcde/elasticPools/pool"
    }
  }
  mock_resource "azurerm_mssql_database" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-data-sql-dev-sec/providers/Microsoft.Sql/servers/eh-data-sql-dev-abcde/databases/db"
    }
  }
  mock_resource "azurerm_private_endpoint" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-data-sql-dev-sec/providers/Microsoft.Network/privateEndpoints/pe"
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
  settings = {
    entra_admin = { login = "eh-sql-admins", object_id = "cccccccc-0000-0000-0000-000000000001" }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_mssql_server.this.public_network_access_enabled == false
    error_message = "Public network access must be disabled."
  }
  assert {
    condition     = azurerm_mssql_server.this.azuread_administrator[0].azuread_authentication_only == true
    error_message = "Server must be Entra-only."
  }
  assert {
    condition     = azurerm_mssql_server.this.minimum_tls_version == "1.2"
    error_message = "TLS 1.2 minimum."
  }
  assert {
    condition     = azurerm_mssql_database.fulfillment.sku_name == "GP_S_Gen5_1" && azurerm_mssql_database.fulfillment.auto_pause_delay_in_minutes == 60 && azurerm_mssql_database.fulfillment.min_capacity == 0.5
    error_message = "fulfillment must be serverless GP_S_Gen5_1 with 60 min auto-pause and 0.5 vCore minimum."
  }
  assert {
    condition     = azurerm_mssql_database.orders.sku_name == "S0"
    error_message = "orders must default to S0."
  }
  assert {
    condition     = alltrue([for d in [azurerm_mssql_database.orders, azurerm_mssql_database.fulfillment, azurerm_mssql_database.adapter] : d.short_term_retention_policy[0].retention_days == 7 && length(d.long_term_retention_policy) == 0])
    error_message = "PITR 7 days, no LTR."
  }
  assert {
    condition     = length(module.private_endpoint) == 1 && module.private_endpoint[0].id != null
    error_message = "Private endpoint must be created by default."
  }
  assert {
    condition     = length(azurerm_mssql_elasticpool.this) == 0 && length(azurerm_mssql_database.adapter_hs) == 0
    error_message = "Elastic pool and Hyperscale are disabled by default."
  }
  assert {
    condition     = toset(keys(output.contract.databases)) == toset(["orders", "fulfillment", "adapter"])
    error_message = "Contract must list the three default databases."
  }
  assert {
    condition     = output.contract.databases.orders.owner_identity_name == "hello-orders-api" && output.contract.databases.fulfillment.owner_identity_name == "hello-durable"
    error_message = "Owners must follow catalog/architecture-matrix.yaml."
  }
  assert {
    condition     = contains([for g in output.contract.databases.fulfillment.grants : g.identity_name], "hello-jobs")
    error_message = "hello-jobs must be granted on fulfillment."
  }
  assert {
    condition     = output.contract.dbm.supported && output.contract.dbm.auth_mode == "entra-managed-identity" && output.contract.dbm.identity_client_id == "bbbbbbbb-0000-0000-0000-000000000009"
    error_message = "DBM metadata must point obs-dbm at Entra managed identity auth."
  }
  assert {
    condition     = output.contract.server.fqdn == "eh-data-sql-dev-abcde.database.windows.net" && can(regex("^/subscriptions/", output.contract.server.id))
    error_message = "Contract server shape."
  }
}

run "optional_pool_and_hyperscale" {
  command = plan

  variables {
    settings = {
      entra_admin              = { login = "eh-sql-admins", object_id = "cccccccc-0000-0000-0000-000000000001" }
      private_endpoint_enabled = false
      elastic_pool             = { enabled = true }
      hyperscale               = { enabled = true }
    }
  }

  assert {
    condition     = length(module.private_endpoint) == 0
    error_message = "No PE when disabled."
  }
  assert {
    condition     = azurerm_mssql_database.adapter_pool[0].sku_name == "ElasticPool" && azurerm_mssql_database.adapter_hs[0].sku_name == "HS_S_Gen5_2"
    error_message = "adapter_pool in pool, adapter_hs Hyperscale serverless."
  }
  assert {
    condition     = toset(keys(output.contract.databases)) == toset(["orders", "fulfillment", "adapter", "adapter_pool", "adapter_hs"])
    error_message = "Contract lists optional databases when enabled."
  }
}

run "rejects_provisioned_fulfillment" {
  command = plan
  variables {
    settings = {
      entra_admin = { login = "eh-sql-admins", object_id = "cccccccc-0000-0000-0000-000000000001" }
      fulfillment = { sku_name = "S0" }
    }
  }
  expect_failures = [var.settings]
}
