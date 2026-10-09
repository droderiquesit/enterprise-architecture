locals {
  db_resources = merge(
    {
      orders      = azurerm_mssql_database.orders
      fulfillment = azurerm_mssql_database.fulfillment
      adapter     = azurerm_mssql_database.adapter
    },
    var.settings.elastic_pool.enabled ? { adapter_pool = azurerm_mssql_database.adapter_pool[0] } : {},
    var.settings.hyperscale.enabled ? { adapter_hs = azurerm_mssql_database.adapter_hs[0] } : {},
  )

  dbm_identity = try(local.identities["obs-dbm"], null)
}

output "contract" {
  description = "platform-db-sql v1 (catalog/contracts/platform-db-sql.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "azure-sql-database"
    server = {
      id                            = azurerm_mssql_server.this.id
      name                          = azurerm_mssql_server.this.name
      fqdn                          = azurerm_mssql_server.this.fully_qualified_domain_name
      port                          = 1433
      version                       = azurerm_mssql_server.this.version
      public_network_access_enabled = false
      minimum_tls_version           = var.settings.minimum_tls_version
      auth_mode                     = "entra-only"
      entra_admin = {
        login     = var.settings.entra_admin.login
        object_id = var.settings.entra_admin.object_id
      }
    }
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    elastic_pool_id = try(azurerm_mssql_elasticpool.this[0].id, null)
    databases = {
      for k, d in local.databases : k => {
        id                           = local.db_resources[k].id
        name                         = local.db_resources[k].name
        fqdn                         = azurerm_mssql_server.this.fully_qualified_domain_name
        port                         = 1433
        sku_name                     = local.db_resources[k].sku_name
        compute_model                = d.compute_model
        dbm_enabled                  = d.dbm_enabled
        catalog_ref                  = d.catalog_ref
        boundary                     = d.boundary
        schemas                      = d.schemas
        auth_mode                    = "entra-managed-identity"
        owner_identity_name          = d.owner
        reader_writer_identity_names = d.readers_writers
        grants                       = local.grants[k]
        connection_hint              = "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433;Database=${local.db_resources[k].name};Authentication=Active Directory Managed Identity;Encrypt=True;"
      }
    }
    grant_script = "platform/data/sql/scripts/grant-db-users.sql"
    # Datadog Database Monitoring metadata for obs-dbm (observability creates the DBM login/users).
    dbm = {
      supported          = true
      engine             = "sqlserver"
      deployment_type    = "sql_database"
      auth_mode          = "entra-managed-identity"
      identity_name      = "obs-dbm"
      identity_client_id = try(local.dbm_identity.client_id, null)
      host               = azurerm_mssql_server.this.fully_qualified_domain_name
      port               = 1433
      resource_id        = azurerm_mssql_server.this.id
      databases          = sort([for k, d in local.databases : k if d.dbm_enabled])
      excluded_databases = { for k, d in local.databases : k => "serverless auto-pause: DBM connections would prevent pausing" if !d.dbm_enabled }
      entra_admin_login  = var.settings.entra_admin.login
      # Run by obs-dbm as the Entra admin: CREATE LOGIN [obs-dbm] FROM EXTERNAL PROVIDER in master,
      # server roles ##MS_ServerStateReader## + ##MS_DefinitionReader##, CREATE USER in each database.
      setup_reference = "https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/"
    }
  }
}
