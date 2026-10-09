output "contract" {
  description = "platform-db-sqlvm v1 (catalog/contracts/platform-db-sqlvm.v1.schema.json). No secrets: *_secret_id fields are Delinea DSV references (dsv://...)."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "sql-server-on-azure-vm"
    vm = {
      id                 = azurerm_windows_virtual_machine.this.id
      name               = azurerm_windows_virtual_machine.this.name
      private_ip_address = azurerm_network_interface.this.private_ip_address
      principal_id       = azurerm_windows_virtual_machine.this.identity[0].principal_id
      # user-assigned identity used by host agents to authenticate to Delinea DSV (null when not attached)
      identity_client_id = try(local.host_identity.client_id, null)
      identity_id        = try(local.host_identity.id, null)
      os                 = "windows"
      image              = "${var.settings.image.publisher}:${var.settings.image.offer}:${var.settings.image.sku}:${var.settings.image.version}"
      auto_shutdown      = var.settings.auto_shutdown.enabled ? "${var.settings.auto_shutdown.time} ${var.settings.auto_shutdown.timezone}" : null
    }
    server = {
      id                            = azurerm_mssql_virtual_machine.this.id
      fqdn                          = azurerm_network_interface.this.private_ip_address
      port                          = 1433
      edition                       = "Developer"
      version                       = "2022"
      public_network_access_enabled = false
      connectivity                  = "PRIVATE"
      auth_mode                     = "sql-login"
      admin_login                   = local.admin_login
      admin_password_secret_id      = local.admin_ref
    }
    databases = {
      adapter = {
        name                = "adapter"
        fqdn                = azurerm_network_interface.this.private_ip_address
        port                = 1433
        boundary            = "db adapter"
        schemas             = ["adapter"]
        auth_mode           = "sql-login"
        owner_identity_name = "hello-dbadapter"
        login               = "dbadapter"
        password_secret_id  = local.dbadapter_ref
      }
    }
    dbm = {
      supported       = true
      engine          = "sqlserver"
      deployment_type = "self_hosted_azure_vm"
      # The Agent runs on the VM itself (observability owns the VM extension) and connects to localhost.
      auth_mode          = "sql-login"
      identity_name      = "obs-dbm"
      username           = "datadog"
      password_secret_id = local.dbm_ref
      host               = "localhost"
      port               = 1433
      resource_id        = azurerm_windows_virtual_machine.this.id
      databases          = ["adapter"]
      admin_login        = local.admin_login
      admin_secret_id    = local.admin_ref
      setup_reference    = "https://docs.datadoghq.com/database_monitoring/setup_sql_server/selfhosted/"
    }
  }
}

locals {
  admin_ref     = lookup(var.foundation_identity.secrets.refs, var.settings.admin_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.admin_secret_name}#value")
  dbadapter_ref = lookup(var.foundation_identity.secrets.refs, var.settings.dbadapter_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.dbadapter_secret_name}#value")
  dbm_ref       = lookup(var.foundation_identity.secrets.refs, var.settings.dbm_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.dbm_secret_name}#value")
}
