locals {
  dbm_identity = try(local.identities["obs-dbm"], null)
}

output "contract" {
  description = "platform-db-postgresql v1 (catalog/contracts/platform-db-postgresql.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "postgresql-flexible"
    server = {
      id                            = azurerm_postgresql_flexible_server.this.id
      name                          = azurerm_postgresql_flexible_server.this.name
      fqdn                          = azurerm_postgresql_flexible_server.this.fqdn
      port                          = 5432
      version                       = var.settings.version
      sku_name                      = var.settings.sku_name
      network_mode                  = var.settings.network_mode
      public_network_access_enabled = false
      auth_mode                     = "entra-only"
      entra_admin = {
        object_id      = var.settings.entra_admin.object_id
        principal_name = var.settings.entra_admin.principal_name
        principal_type = var.settings.entra_admin.principal_type
      }
      server_parameters = local.server_parameters
    }
    private_endpoint = {
      enabled            = !local.vnet_mode
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    databases = {
      for db, d in local.databases : db => {
        id                           = azurerm_postgresql_flexible_server_database.this[db].id
        name                         = db
        fqdn                         = azurerm_postgresql_flexible_server.this.fqdn
        port                         = 5432
        boundary                     = d.boundary
        schemas                      = [d.schema]
        auth_mode                    = "entra-managed-identity"
        owner_identity_name          = d.owner
        reader_writer_identity_names = []
        grants                       = try(local.grants[db], [])
        connection_hint              = "host=${azurerm_postgresql_flexible_server.this.fqdn} port=5432 dbname=${db} user=${d.owner} sslmode=require (password = Entra access token for https://ossrdbms-aad.database.windows.net/.default)"
      }
    }
    elastic_cluster = var.settings.elastic_cluster.enabled ? {
      id                  = azurerm_postgresql_flexible_server.elastic[0].id
      name                = azurerm_postgresql_flexible_server.elastic[0].name
      fqdn                = azurerm_postgresql_flexible_server.elastic[0].fqdn
      port                = 5432
      node_count          = var.settings.elastic_cluster.node_count
      database            = "adapter"
      boundary            = "distributed table adapter.records"
      owner_identity_name = "hello-dbadapter"
      private_endpoint_id = module.private_endpoint_elastic[0].id
      distribution_script = "platform/data/postgresql/scripts/elastic-distribute.sql"
    } : null
    grant_script = "platform/data/postgresql/scripts/grant-db-users.sql"
    # Datadog DBM: the obs-dbm root registers obs-dbm as an Entra principal (pgaadauth) while signed in
    # as a member of the Entra admin group, then grants pg_read_all_settings + pg_read_all_stats (PG 16+).
    dbm = {
      supported           = true
      engine              = "postgres"
      deployment_type     = "flexible_server"
      auth_mode           = "entra-managed-identity"
      identity_name       = "obs-dbm"
      identity_client_id  = try(local.dbm_identity.client_id, null)
      identity_object_id  = try(local.dbm_identity.principal_id, null)
      host                = azurerm_postgresql_flexible_server.this.fqdn
      port                = 5432
      resource_id         = azurerm_postgresql_flexible_server.this.id
      databases           = sort(keys(local.databases))
      entra_admin_login   = var.settings.entra_admin.principal_name
      required_parameters = local.server_parameters
      setup_reference     = "https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/"
    }
  }
}
