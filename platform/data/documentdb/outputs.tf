output "contract" {
  description = "platform-db-documentdb v1 (catalog/contracts/platform-db-documentdb.v1.schema.json). No secrets (dsv:// references only)."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "azure-documentdb"
    cluster = {
      id                            = azurerm_mongo_cluster.this.id
      name                          = azurerm_mongo_cluster.this.name
      host                          = "${azurerm_mongo_cluster.this.name}.global.mongocluster.cosmos.azure.com"
      port                          = 10260
      compute_tier                  = var.settings.compute_tier
      server_version                = var.settings.server_version
      high_availability             = false
      public_network_access_enabled = false
      authentication_methods        = ["NativeAuth", "MicrosoftEntraID"]
      admin_login                   = local.admin_login
      admin_password_secret_id      = lookup(var.foundation_identity.secrets.refs, var.settings.admin_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.admin_secret_name}#value")
    }
    auth_mode = "entra-oidc"
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      group_id           = "MongoCluster"
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    databases = {
      adapter = {
        name                = "adapter"
        boundary            = local.boundary
        owner_identity_name = local.owner
        containers          = { records = { name = "records", partition_key = "_id" } }
        connection_hint     = "mongodb+srv://<client id>@${azurerm_mongo_cluster.this.name}.global.mongocluster.cosmos.azure.com/?tls=true&authMechanism=MONGODB-OIDC&retrywrites=false&maxIdleTimeMS=120000"
      }
    }
    rbac = local.owner_principal_id == null ? [] : [{
      identity_name = local.owner
      principal_id  = local.owner_principal_id
      role          = "root (admin db; azurerm supports no narrower role)"
      scope         = azurerm_mongo_cluster.this.id
    }]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure DocumentDB (MongoDB-compatible); use the Agent MongoDB integration if needed."
    }
  }
}
