locals {
  host = azurerm_function_app_flex_consumption.this.default_hostname
  url  = "https://${local.host}"
}

output "contract" {
  description = "deploy-durable contract v1 (catalog/contracts/deploy-durable.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "functions-flex-consumption"
    resource_group_name = local.rg
    task_hub            = local.task_hub
    function_app = {
      id       = azurerm_function_app_flex_consumption.this.id
      name     = azurerm_function_app_flex_consumption.this.name
      hostname = local.host
      private  = local.private
    }
    reconciliation_app = local.y1_enabled ? {
      id       = azurerm_windows_function_app.reconciliation[0].id
      name     = azurerm_windows_function_app.reconciliation[0].name
      hostname = azurerm_windows_function_app.reconciliation[0].default_hostname
    } : null
    apps = merge(
      {
        "hello-durable" = {
          id             = azurerm_function_app_flex_consumption.this.id
          name           = azurerm_function_app_flex_consumption.this.name
          type           = "Microsoft.Web/sites"
          service        = local.svc
          architecture   = "functions-flex-consumption"
          app_log_route  = module.env.log_route
          sidecar        = false
          url            = local.url
          urls           = { public = local.private ? null : local.url, private = local.url }
          health_path    = "/api/healthz"
          readiness_path = null
          version_path   = "/api/version"
          scale_to_zero  = var.settings.always_ready_instances == 0
          min_replicas   = var.settings.always_ready_instances
          max_replicas   = var.settings.maximum_instance_count
          version        = local.artifact_version[local.artifact]
          image          = null
          identity_name  = local.flex.identity
        }
      },
      local.y1_enabled ? {
        "hello-durable-reconciliation" = {
          id             = azurerm_windows_function_app.reconciliation[0].id
          name           = azurerm_windows_function_app.reconciliation[0].name
          type           = "Microsoft.Web/sites"
          service        = local.svc
          architecture   = "functions-consumption-windows"
          app_log_route  = module.env.log_route
          sidecar        = false
          url            = "https://${azurerm_windows_function_app.reconciliation[0].default_hostname}"
          urls           = { public = "https://${azurerm_windows_function_app.reconciliation[0].default_hostname}", private = null }
          health_path    = "/api/healthz"
          readiness_path = null
          version_path   = "/api/version"
          scale_to_zero  = true
          min_replicas   = 0
          max_replicas   = 0
          version        = local.artifact_version[local.artifact]
          image          = null
          identity_name  = local.fx.consumption_windows.identity
        }
      } : {},
    )
    # The Functions apps expose /api/healthz and /api/version but no /readyz: probed by scripts/smoke.sh, not
    # by tools/smoke/smoke.py (which requires /healthz, /readyz and /version at the endpoint root).
    endpoints     = {}
    idle_behavior = { "hello-durable" = { scale_to_zero = var.settings.always_ready_instances == 0 } }
    deploy_steps = [{
      kind           = "functionapp-flex"
      app            = "hello-durable"
      resource_id    = azurerm_function_app_flex_consumption.this.id
      name           = azurerm_function_app_flex_consumption.this.name
      resource_group = local.rg
      package_uri    = try(var.artifacts[local.artifact].package_url, null)
      package_sha256 = try(var.artifacts[local.artifact].package_sha256, null)
      slot           = null
    }]
    rollback = {
      method = "redeploy-previous-package"
      how    = "Flex Consumption has no slots: re-run deploy-zip.sh with the previous svc-durable package (the Y1 app follows the package URL in WEBSITE_RUN_FROM_PACKAGE on the next apply)"
    }
  }
}
