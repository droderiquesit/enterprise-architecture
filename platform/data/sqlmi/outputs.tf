locals {
  dbm_identity = try(local.identities["obs-dbm"], null)
}

output "contract" {
  description = "platform-db-sqlmi v1 (catalog/contracts/platform-db-sqlmi.v1.schema.json). No secrets."
  value = {
    enabled             = local.enabled
    resource_group_name = try(azurerm_resource_group.this[0].name, null)
    engine              = "azure-sql-managed-instance"
    server = local.enabled ? {
      id                            = local.mi_id
      name                          = local.mi_name
      fqdn                          = local.mi_fqdn
      port                          = 1433
      sku_name                      = var.settings.sku_name
      vcores                        = var.settings.vcores
      pricing_model                 = var.settings.free_offer ? "Freemium" : "Regular"
      public_network_access_enabled = false
      minimum_tls_version           = var.settings.minimum_tls_version
      auth_mode                     = "entra-only"
      entra_admin = {
        login     = var.settings.entra_admin.login
        object_id = var.settings.entra_admin.object_id
      }
    } : null
    databases = local.enabled ? {
      for db, d in local.databases : db => {
        id                           = azurerm_mssql_managed_database.this[db].id
        name                         = db
        fqdn                         = local.mi_fqdn
        port                         = 1433
        boundary                     = d.boundary
        schemas                      = [d.schema]
        auth_mode                    = "entra-managed-identity"
        owner_identity_name          = d.owner
        reader_writer_identity_names = []
        grants                       = try(local.grants[db], [])
      }
    } : {}
    grant_script = "platform/data/sql/scripts/grant-db-users.sql"
    dbm = local.enabled ? {
      supported          = true
      engine             = "sqlserver"
      deployment_type    = "managed_instance"
      auth_mode          = "entra-managed-identity"
      identity_name      = "obs-dbm"
      identity_client_id = try(local.dbm_identity.client_id, null)
      host               = local.mi_fqdn
      port               = 1433
      resource_id        = local.mi_id
      databases          = sort(keys(local.databases))
      entra_admin_login  = var.settings.entra_admin.login
      # obs-dbm (as Entra admin): CREATE LOGIN [obs-dbm] FROM EXTERNAL PROVIDER; GRANT CONNECT ANY DATABASE,
      # VIEW SERVER STATE, VIEW ANY DEFINITION.
      setup_reference = "https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/"
    } : null
  }
}
