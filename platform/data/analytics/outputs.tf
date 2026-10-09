output "contract" {
  description = "platform-data-analytics v1 (catalog/contracts/platform-data-analytics.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    blob = var.settings.blob.enabled ? {
      enabled                       = true
      id                            = azurerm_storage_account.blob[0].id
      name                          = azurerm_storage_account.blob[0].name
      endpoint                      = azurerm_storage_account.blob[0].primary_blob_endpoint
      container                     = "adapter"
      boundary                      = "container adapter"
      owner_identity_name           = "hello-dbadapter"
      auth_mode                     = "entra-rbac"
      public_network_access_enabled = false
      shared_key_enabled            = false
      private_endpoint_ids          = [for m in module.pe_blob : m.id]
    } : null
    adls = var.settings.adls.enabled ? {
      enabled                       = true
      id                            = azurerm_storage_account.adls[0].id
      name                          = azurerm_storage_account.adls[0].name
      endpoint                      = azurerm_storage_account.adls[0].primary_dfs_endpoint
      filesystem                    = "adapter"
      boundary                      = "filesystem adapter"
      owner_identity_name           = "hello-dbadapter"
      auth_mode                     = "entra-rbac"
      public_network_access_enabled = false
      shared_key_enabled            = false
      private_endpoint_ids          = [for m in module.pe_adls : m.id]
    } : null
    data_explorer = var.settings.data_explorer.enabled ? {
      enabled                       = true
      id                            = azurerm_kusto_cluster.this[0].id
      name                          = azurerm_kusto_cluster.this[0].name
      uri                           = azurerm_kusto_cluster.this[0].uri
      data_ingestion_uri            = azurerm_kusto_cluster.this[0].data_ingestion_uri
      sku_name                      = var.settings.data_explorer.sku_name
      auto_stop_enabled             = var.settings.data_explorer.auto_stop_enabled
      database                      = "adapter"
      table                         = "Records"
      boundary                      = "database adapter / table Records"
      owner_identity_name           = "hello-dbadapter"
      auth_mode                     = "entra-rbac"
      public_network_access_enabled = false
      private_endpoint_ids          = [for m in module.pe_kusto : m.id]
    } : null
    search = var.settings.search.enabled ? {
      enabled                       = true
      id                            = azurerm_search_service.this[0].id
      name                          = azurerm_search_service.this[0].name
      endpoint                      = "https://${azurerm_search_service.this[0].name}.search.windows.net"
      sku                           = var.settings.search.sku
      index                         = "adapter-records"
      boundary                      = "index adapter-records"
      owner_identity_name           = "hello-dbadapter"
      auth_mode                     = "entra-rbac"
      local_auth_enabled            = false
      public_network_access_enabled = false
      private_endpoint_ids          = [for m in module.pe_search : m.id]
    } : null
    synapse = var.settings.synapse.enabled ? {
      enabled                       = true
      id                            = azurerm_synapse_workspace.this[0].id
      name                          = azurerm_synapse_workspace.this[0].name
      connectivity_endpoints        = azurerm_synapse_workspace.this[0].connectivity_endpoints
      auth_mode                     = "entra-only"
      public_network_access_enabled = false
      private_endpoint_ids          = [for m in module.pe_synapse : m.id]
    } : null
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not cover Storage, ADX, AI Search or Synapse; Azure integration metrics apply."
    }
  }
}
