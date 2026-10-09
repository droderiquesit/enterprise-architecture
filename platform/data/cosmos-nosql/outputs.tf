output "contract" {
  description = "platform-db-cosmos-nosql v1 (catalog/contracts/platform-db-cosmos-nosql.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "cosmosdb"
    api                 = "nosql"
    account = {
      id                            = module.account.id
      name                          = module.account.name
      endpoint                      = module.account.api_endpoint
      host                          = module.account.api_host
      port                          = module.account.api_port
      capacity_mode                 = var.settings.capacity_mode
      public_network_access_enabled = false
      local_auth_enabled            = false
      backup                        = "Continuous7Days"
    }
    auth_mode     = "entra-rbac"
    key_secret_id = null
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      group_id           = module.account.private_endpoint_group_id
      id                 = module.account.private_endpoint_id
      private_ip_address = module.account.private_ip_address
    }
    databases = {
      for db, d in local.databases : db => {
        id                  = azurerm_cosmosdb_sql_database.this[db].id
        name                = db
        boundary            = d.boundary
        owner_identity_name = d.owner
        containers = {
          for c, cfg in d.containers : c => {
            id            = azurerm_cosmosdb_sql_container.this["${db}/${c}"].id
            name          = c
            partition_key = cfg.partition_key
          }
        }
      }
    }
    rbac = [
      for db, r in local.rbac : {
        identity_name = r.identity_name
        principal_id  = r.principal_id
        role          = "Cosmos DB Built-in Data Contributor"
        scope         = r.scope
      }
    ]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure Cosmos DB; use the Azure integration metrics and OTel client spans."
    }
  }
}
