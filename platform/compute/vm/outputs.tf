output "contract" {
  description = "platform-vm contract v1 (catalog/contracts/platform-vm.v1.schema.json). No credentials."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    location            = local.location
    subnet_id           = local.subnet_id
    auto_shutdown       = var.settings.auto_shutdown.enabled ? "${var.settings.auto_shutdown.time} ${var.settings.auto_shutdown.timezone}" : null
    vms = merge(
      local.linux.enabled ? {
        linux = {
          id                    = azurerm_linux_virtual_machine.this[0].id
          name                  = azurerm_linux_virtual_machine.this[0].name
          computer_name         = azurerm_linux_virtual_machine.this[0].computer_name
          os_type               = "Linux"
          os_image              = "${local.linux.image.offer}/${local.linux.image.sku}"
          private_ip            = azurerm_network_interface.this["linux"].private_ip_address
          size                  = local.linux.size
          workload              = local.linux.identity
          identity_id           = local.identities[local.linux.identity].id
          identity_client_id    = local.identities[local.linux.identity].client_id
          identity_principal_id = local.identities[local.linux.identity].principal_id
          system_principal_id   = try(azurerm_linux_virtual_machine.this[0].identity[0].principal_id, null)
          app_root              = "/opt/hello"
          log_dir               = "/var/log/hello"
        }
      } : {},
      local.windows.enabled ? {
        windows = {
          id                    = azurerm_windows_virtual_machine.this[0].id
          name                  = azurerm_windows_virtual_machine.this[0].name
          computer_name         = azurerm_windows_virtual_machine.this[0].computer_name
          os_type               = "Windows"
          os_image              = "${local.windows.image.offer}/${local.windows.image.sku}"
          private_ip            = azurerm_network_interface.this["windows"].private_ip_address
          size                  = local.windows.size
          workload              = local.windows.identity
          identity_id           = local.identities[local.windows.identity].id
          identity_client_id    = local.identities[local.windows.identity].client_id
          identity_principal_id = local.identities[local.windows.identity].principal_id
          system_principal_id   = try(azurerm_windows_virtual_machine.this[0].identity[0].principal_id, null)
          app_root              = "C:\\hello"
          log_dir               = "C:\\hello\\logs"
        }
      } : {},
    )
  }
}
