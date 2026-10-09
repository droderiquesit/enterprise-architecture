output "contract" {
  description = "platform-db-cosmos-table v1 (catalog/contracts/platform-db-cosmos-table.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "cosmosdb"
    api                 = "table"
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
      adapterrecords = {
        id                  = azurerm_cosmosdb_table.adapterrecords.id
        name                = "adapterrecords"
        boundary            = local.boundary
        owner_identity_name = local.owner
        containers          = {}
      }
    }
    rbac = local.owner_principal_id == null ? [] : [{
      identity_name = local.owner
      principal_id  = local.owner_principal_id
      role          = "Cosmos DB Built-in Data Contributor (table)"
      scope         = module.account.id
    }]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure Cosmos DB for Table."
    }
  }
}
