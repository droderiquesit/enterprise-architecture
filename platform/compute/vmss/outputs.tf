output "contract" {
  description = "platform-vmss contract v1 (catalog/contracts/platform-vmss.v1.schema.json). No credentials."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    location            = local.location
    subnet_id           = local.subnet_id
    scale_sets = {
      for k, s in local.scale_sets : k => {
        id                    = s.id
        name                  = k == "flexible" ? azurerm_orchestrated_virtual_machine_scale_set.flexible[0].name : azurerm_linux_virtual_machine_scale_set.uniform[0].name
        orchestration_mode    = k == "flexible" ? "Flexible" : "Uniform"
        upgrade_mode          = k == "flexible" ? "Manual" : "Manual"
        os_type               = "Linux"
        os_image              = "${var.settings.image.offer}/${var.settings.image.sku}"
        sku                   = s.sku
        min_instances         = s.min_instances
        max_instances         = s.max_instances
        workload              = s.identity
        identity_id           = local.identities[s.identity].id
        identity_client_id    = local.identities[s.identity].client_id
        identity_principal_id = local.identities[s.identity].principal_id
        app_root              = "/opt/hello"
        log_dir               = "/var/log/hello"
      }
    }
  }
}
