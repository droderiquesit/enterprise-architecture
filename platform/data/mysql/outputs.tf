output "contract" {
  description = "platform-db-mysql v1 (catalog/contracts/platform-db-mysql.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "mysql-flexible"
    server = {
      id                            = azurerm_mysql_flexible_server.this.id
      name                          = azurerm_mysql_flexible_server.this.name
      fqdn                          = azurerm_mysql_flexible_server.this.fqdn
      port                          = 3306
      version                       = var.settings.version
      sku_name                      = var.settings.sku_name
      network_mode                  = var.settings.network_mode
      public_network_access_enabled = false
      # Entra + native: native auth stays on for the Datadog DBM user (Entra not documented for MySQL DBM).
      auth_mode = "entra-and-native"
      entra_admin = {
        login     = var.settings.entra_admin.login
        object_id = var.settings.entra_admin.object_id
      }
      server_identity_id = local.server_uami
      server_parameters  = local.server_parameters
    }
    private_endpoint = {
      enabled            = !local.vnet_mode
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    databases = {
      for db, d in local.databases : db => {
        id                           = azurerm_mysql_flexible_database.this[db].id
        name                         = db
        fqdn                         = azurerm_mysql_flexible_server.this.fqdn
        port                         = 3306
        boundary                     = d.boundary
        schemas                      = [db]
        auth_mode                    = "entra-managed-identity"
        owner_identity_name          = d.owner
        reader_writer_identity_names = []
        grants                       = try(local.grants[db], [])
        connection_hint              = "host=${azurerm_mysql_flexible_server.this.fqdn} port=3306 db=${db} user=${d.owner} ssl=required (password = Entra token for https://ossrdbms-aad.database.windows.net/.default; cleartext plugin over TLS)"
      }
    }
    grant_script = "platform/data/mysql/scripts/grant-db-users.sql"
    dbm = {
      supported           = true
      engine              = "mysql"
      deployment_type     = "flexible_server"
      auth_mode           = "native-password"
      identity_name       = "obs-dbm"
      username            = "datadog"
      password_secret_id  = "${local.kv_uri}/secrets/${var.settings.dbm_password_secret_name}"
      host                = azurerm_mysql_flexible_server.this.fqdn
      port                = 3306
      resource_id         = azurerm_mysql_flexible_server.this.id
      databases           = sort(keys(local.databases))
      entra_admin_login   = var.settings.entra_admin.login
      required_parameters = local.server_parameters
      setup_reference     = "https://docs.datadoghq.com/database_monitoring/setup_mysql/azure/"
      limitations         = ["Query Activity and Wait Event collection are not supported on Flexible Server (Datadog docs)."]
    }
  }
}
