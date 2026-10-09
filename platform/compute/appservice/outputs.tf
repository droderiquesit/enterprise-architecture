output "contract" {
  description = "platform-appservice contract v1 (catalog/contracts/platform-appservice.v1.schema.json)."
  value = {
    resource_group_name   = azurerm_resource_group.this.name
    location              = local.location
    integration_subnet_id = local.subnets["appsvc-integration"].id
    plans = merge(
      { for k, p in azurerm_service_plan.this : k => { id = p.id, name = p.name, os_type = p.os_type, sku = p.sku_name } },
      local.logicapps.enabled ? { logicapps = { id = azurerm_service_plan.logicapps[0].id, name = azurerm_service_plan.logicapps[0].name, os_type = "Windows", sku = local.logicapps.sku } } : {},
    )
    # Functions on a Dedicated plan run on the Linux plan (no separate plan).
    functions_dedicated_plan = contains(keys(local.enabled_plans), "linux") ? "linux" : null
    logicapps_storage = local.logicapps.enabled ? {
      id                  = azurerm_storage_account.logicapps[0].id
      name                = azurerm_storage_account.logicapps[0].name
      private             = local.logicapps.storage_private
      blob_endpoint       = azurerm_storage_account.logicapps[0].primary_blob_endpoint
      shared_key_required = true
    } : null
  }
}
