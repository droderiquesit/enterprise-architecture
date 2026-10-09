output "contract" {
  description = "platform-db-cosmos-gremlin v1 (catalog/contracts/platform-db-cosmos-gremlin.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "cosmosdb"
    api                 = "gremlin"
    account = {
      id                            = module.account.id
      name                          = module.account.name
      endpoint                      = module.account.api_endpoint
      host                          = module.account.api_host
      port                          = module.account.api_port
      capacity_mode                 = var.settings.capacity_mode
      public_network_access_enabled = false
      local_auth_enabled            = true
      backup                        = "Continuous7Days"
      username                      = "/dbs/adapter/colls/records"
    }
    auth_mode     = "key"
    key_secret_id = local.key_secret_id
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      group_id           = module.account.private_endpoint_group_id
      id                 = module.account.private_endpoint_id
      private_ip_address = module.account.private_ip_address
    }
    databases = {
      adapter = {
        id                  = azurerm_cosmosdb_gremlin_database.adapter.id
        name                = "adapter"
        boundary            = local.boundary
        owner_identity_name = local.owner
        containers = {
          records = {
            id            = azurerm_cosmosdb_gremlin_graph.records.id
            name          = "records"
            partition_key = "/pk"
          }
        }
      }
    }
    rbac = []
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure Cosmos DB for Apache Gremlin."
    }
  }
}
