output "contract" {
  description = "deploy-frontend contract v1 (catalog/contracts/deploy-frontend.v1.schema.json). No secrets (no deployment token)."
  value = {
    component           = local.component
    architecture        = "static-web-apps"
    resource_group_name = azurerm_resource_group.this.name
    url                 = local.site_url
    static_web_app = {
      id               = azurerm_static_web_app.this.id
      name             = azurerm_static_web_app.this.name
      default_hostname = azurerm_static_web_app.this.default_host_name
      location         = var.settings.swa_location
      sku              = var.settings.sku
    }
    apps = {
      "hello-frontend" = {
        id             = azurerm_static_web_app.this.id
        name           = azurerm_static_web_app.this.name
        type           = "Microsoft.Web/staticSites"
        service        = "hello-frontend"
        architecture   = "static-web-apps"
        app_log_route  = "none"
        sidecar        = false
        url            = local.site_url
        urls           = { public = local.site_url, private = null }
        health_path    = "/healthz"
        readiness_path = "/readyz"
        version_path   = "/version"
        scale_to_zero  = true
        min_replicas   = 0
        max_replicas   = 0
        version        = local.version
        image          = null
        identity_name  = null
      }
    }
    endpoints     = { "hello-frontend" = local.site_url }
    idle_behavior = { "hello-frontend" = { scale_to_zero = true } }
    api_origin    = local.api_origin
    # Runtime files rendered here and written by scripts/deploy-swa.sh into the bundle before upload.
    runtime_files = {
      "config.json"              = jsonencode(local.config)
      "staticwebapp.config.json" = jsonencode(local.swa_config)
      "version.json"             = jsonencode(local.version_doc)
      "healthz.json"             = jsonencode({ status = "ok", service = "hello-frontend" })
    }
    deploy_steps = [{
      kind           = "swa"
      app            = "hello-frontend"
      resource_id    = azurerm_static_web_app.this.id
      name           = azurerm_static_web_app.this.name
      resource_group = azurerm_resource_group.this.name
      package_uri    = try(var.artifacts[local.artifact].package_url, null)
      package_sha256 = try(var.artifacts[local.artifact].package_sha256, null)
      slot           = null
    }]
    rollback = {
      method = "redeploy-previous-bundle"
      how    = "re-run deploy-swa.sh with the previous svc-frontend package (SWA keeps no deployment slots on Free)"
    }
  }
}
