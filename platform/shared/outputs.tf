output "contract" {
  description = "platform-shared contract v1 (catalog/contracts/platform-shared.v1.schema.json). No secrets."
  value = {
    resource_group_name        = azurerm_resource_group.this.name
    location                   = local.location
    acr_id                     = azurerm_container_registry.this.id
    acr_name                   = azurerm_container_registry.this.name
    acr_login_server           = azurerm_container_registry.this.login_server
    acr_sku                    = azurerm_container_registry.this.sku
    acr_private                = local.acr_premium && var.settings.acr_private_endpoint_enabled
    acr_public_network_access  = azurerm_container_registry.this.public_network_access_enabled
    acr_pull_identities        = sort(keys(local.acr_pull))
    acr_push_identities        = sort(keys(local.acr_push))
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
    log_analytics_customer_id  = azurerm_log_analytics_workspace.this.workspace_id
    log_analytics_name         = azurerm_log_analytics_workspace.this.name
  }
}
