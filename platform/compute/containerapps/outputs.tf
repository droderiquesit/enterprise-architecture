output "contract" {
  description = "platform-containerapps contract v1 (catalog/contracts/platform-containerapps.v1.schema.json)."
  value = {
    resource_group_name      = azurerm_resource_group.this.name
    location                 = local.location
    environment_id           = azurerm_container_app_environment.this.id
    environment_name         = azurerm_container_app_environment.this.name
    default_domain           = azurerm_container_app_environment.this.default_domain
    static_ip_address        = azurerm_container_app_environment.this.static_ip_address
    ingress_mode             = var.settings.ingress_mode
    internal                 = local.internal
    infrastructure_subnet_id = local.subnets["aca-infra"].id
    workload_profiles        = [for p in local.profiles : p.name]
    dedicated_profile_name   = var.settings.dedicated_profile.enabled ? var.settings.dedicated_profile.name : null
    logs_destination         = var.settings.logs_destination
    private_dns_zone_id      = local.private_dns ? azurerm_private_dns_zone.env[0].id : null
    zone_redundant           = var.settings.zone_redundancy_enabled
  }
}
