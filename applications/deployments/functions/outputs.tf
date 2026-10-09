locals {
  quote_fqdn = local.aca_enabled ? try(azapi_resource.quote[0].output.properties.configuration.ingress.fqdn, null) : null
}

output "contract" {
  description = "deploy-functions contract v1 (catalog/contracts/deploy-functions.v1.schema.json). No secrets."
  value = {
    component    = local.component
    architecture = "functions"
    function_apps = merge(
      { for h, a in azurerm_linux_function_app.this : h => {
        id        = a.id
        name      = a.name
        hostname  = a.default_hostname
        functions = [local.hosts[h].owns]
      } },
      local.aca_enabled ? { aca = { id = azapi_resource.quote[0].id, name = azapi_resource.quote[0].name, hostname = local.quote_fqdn, functions = [local.fn.quote] } } : {},
    )
    apps = merge(
      { for h, a in azurerm_linux_function_app.this : "hello-functions-${h}" => {
        id             = a.id
        name           = a.name
        type           = "Microsoft.Web/sites"
        service        = local.svc
        architecture   = local.hosts[h].arch
        app_log_route  = module.env[h].log_route
        sidecar        = false
        url            = "https://${a.default_hostname}"
        urls           = { public = local.private ? null : "https://${a.default_hostname}", private = "https://${a.default_hostname}" }
        health_path    = null
        readiness_path = null
        version_path   = null
        scale_to_zero  = false
        min_replicas   = 1
        max_replicas   = h == "premium" ? var.settings.premium_max_scale_out : 1
        version        = local.artifact_version[local.artifact]
        image          = null
        identity_name  = "hello-functions"
      } },
      local.aca_enabled ? { "hello-functions-aca" = {
        id             = azapi_resource.quote[0].id
        name           = azapi_resource.quote[0].name
        type           = "Microsoft.App/containerApps"
        service        = local.svc
        architecture   = "functions-on-container-apps"
        app_log_route  = module.env["aca"].log_route
        sidecar        = length(local.aca_patch.sidecars) > 0
        url            = local.quote_fqdn == null ? null : "https://${local.quote_fqdn}"
        urls           = { public = null, private = local.quote_fqdn == null ? null : "https://${local.quote_fqdn}" }
        health_path    = "/api/quote"
        readiness_path = null
        version_path   = null
        scale_to_zero  = true
        min_replicas   = 0
        max_replicas   = var.settings.aca_max_replicas
        version        = local.artifact_version[local.artifact]
        image          = try(var.artifacts[local.artifact].image, null)
        identity_name  = "hello-functions"
      } } : {},
    )
    endpoints     = {}
    idle_behavior = merge({ for h in keys(local.hosts) : "hello-functions-${h}" => { scale_to_zero = false } }, local.aca_enabled ? { "hello-functions-aca" = { scale_to_zero = true } } : {})
    deploy_steps  = []
    rollback = {
      method = "redeploy-previous-artifact"
      how    = "premium/dedicated run from the package URL in WEBSITE_RUN_FROM_PACKAGE: re-apply with the previous svc-functions artifact; ACA quote: previous image digest (single revision)"
    }
  }
}
