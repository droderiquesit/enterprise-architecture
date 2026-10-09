output "contract" {
  description = "platform-functions contract v1 (catalog/contracts/platform-functions.v1.schema.json). No keys."
  value = {
    resource_group_name        = azurerm_resource_group.this.name
    location                   = local.location
    flex_integration_subnet_id = try(local.subnets["flex-integration"].id, null)
    integration_subnet_id      = try(local.subnets["appsvc-integration"].id, null)
    private_endpoints_enabled  = local.pe
    flex = {
      for k, a in var.settings.flex_apps : k => {
        plan_id                  = azurerm_service_plan.flex[k].id
        plan_name                = azurerm_service_plan.flex[k].name
        identity                 = a.identity
        storage_account_id       = module.flex_storage[k].id
        storage_account_name     = module.flex_storage[k].name
        blob_endpoint            = module.flex_storage[k].endpoints.blob
        queue_endpoint           = module.flex_storage[k].endpoints.queue
        table_endpoint           = module.flex_storage[k].endpoints.table
        deployment_container     = "deploy-${k}"
        deployment_container_url = module.flex_storage[k].containers["deploy-${k}"].url
      }
    }
    durable_storage = var.settings.durable_storage.enabled ? {
      storage_account_id   = module.durable_storage[0].id
      storage_account_name = module.durable_storage[0].name
      blob_endpoint        = module.durable_storage[0].endpoints.blob
      queue_endpoint       = module.durable_storage[0].endpoints.queue
      table_endpoint       = module.durable_storage[0].endpoints.table
      identity             = var.settings.durable_storage.identity
    } : null
    premium = local.premium.enabled ? {
      plan_id              = azurerm_service_plan.premium[0].id
      plan_name            = azurerm_service_plan.premium[0].name
      sku                  = local.premium.sku
      identity             = local.premium.identity
      storage_account_id   = module.premium_storage[0].id
      storage_account_name = module.premium_storage[0].name
      blob_endpoint        = module.premium_storage[0].endpoints.blob
      package_container    = "packages"
    } : null
    consumption_windows = local.y1.enabled ? {
      plan_id              = azurerm_service_plan.consumption_windows[0].id
      plan_name            = azurerm_service_plan.consumption_windows[0].name
      identity             = local.y1.identity
      storage_account_id   = module.consumption_storage[0].id
      storage_account_name = module.consumption_storage[0].name
      blob_endpoint        = module.consumption_storage[0].endpoints.blob
      package_container    = "packages"
    } : null
    durable_task_scheduler = local.dts.enabled ? {
      scheduler_id = azapi_resource.dts_scheduler[0].id
      endpoint     = try(azapi_resource.dts_scheduler[0].output.properties.endpoint, null)
      task_hub     = local.dts.task_hub
      task_hub_id  = azapi_resource.dts_task_hub[0].id
    } : null
  }
}
