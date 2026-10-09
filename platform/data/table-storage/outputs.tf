output "contract" {
  description = "platform-db-table-storage v1 (catalog/contracts/platform-db-table-storage.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "azure-table-storage"
    account = {
      id                            = azurerm_storage_account.this.id
      name                          = azurerm_storage_account.this.name
      endpoint                      = azurerm_storage_account.this.primary_table_endpoint
      port                          = 443
      public_network_access_enabled = false
      shared_key_enabled            = false
    }
    auth_mode = "entra-rbac"
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      group_id           = "table"
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    databases = {
      for t, d in local.tables : t => {
        id                  = azurerm_storage_table.this[t].resource_manager_id
        name                = t
        boundary            = d.boundary
        owner_identity_name = d.owner
      }
    }
    rbac = [for t, d in local.grants : {
      identity_name = d.owner
      principal_id  = local.identities[d.owner].principal_id
      role          = "Storage Table Data Contributor"
      scope         = azurerm_storage_table.this[t].resource_manager_id
    }]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure Table Storage."
    }
  }
}
