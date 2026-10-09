locals {
  adapters = merge(
    { for f, a in module.aca : f => {
      id             = a.id
      name           = a.name
      type           = "Microsoft.App/containerApps"
      service        = "${local.svc}-${f}"
      architecture   = local.hosting[f] == "aca-dedicated" ? "container-apps-dedicated" : "container-apps-consumption"
      hosting        = local.hosting[f]
      app_log_route  = module.env[f].log_route
      sidecar        = a.has_sidecar
      url            = a.url
      urls           = { public = null, private = a.url }
      health_path    = "/healthz"
      readiness_path = "/readyz"
      version_path   = "/version"
      scale_to_zero  = a.scale_to_zero
      min_replicas   = try(var.settings.families[f].min_replicas, 0)
      max_replicas   = try(var.settings.families[f].max_replicas, 2)
    } },
    { for f, a in module.appsvc : f => {
      id             = a.id
      name           = a.name
      type           = "Microsoft.Web/sites"
      service        = "${local.svc}-${f}"
      architecture   = "app-service-linux-code"
      hosting        = "appservice"
      app_log_route  = module.env[f].log_route
      sidecar        = false
      url            = a.url
      urls           = { public = a.private ? null : a.url, private = a.url }
      health_path    = "/healthz"
      readiness_path = "/readyz"
      version_path   = "/version"
      scale_to_zero  = false
      min_replicas   = 1
      max_replicas   = 1
    } },
    { for f, e in azurerm_virtual_machine_scale_set_extension.sqlvm_adapter : f => {
      id             = local.uniform_vmss.id
      name           = local.uniform_vmss.name
      type           = "Microsoft.Compute/virtualMachineScaleSets"
      service        = "${local.svc}-${f}"
      architecture   = "vmss-uniform"
      hosting        = "vmss"
      app_log_route  = module.env[f].log_route
      sidecar        = false
      url            = null # no load balancer in front of the uniform scale set (instance IPs are dynamic)
      urls           = { public = null, private = null }
      health_path    = "/healthz"
      readiness_path = "/readyz"
      version_path   = "/version"
      scale_to_zero  = false
      min_replicas   = 1
      max_replicas   = 1
    } },
  )
}

output "contract" {
  description = "deploy-dbadapters contract v1 (catalog/contracts/deploy-dbadapters.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "multi"
    resource_group_name = azurerm_resource_group.this.name
    version             = local.artifact_version[local.artifact]
    adapters            = local.adapters
    apps                = { for f, a in local.adapters : a.service => merge(a, { version = local.artifact_version[local.artifact], image = a.type == "Microsoft.App/containerApps" ? try(var.artifacts[local.artifact].image, null) : null, identity_name = local.svc }) }
    skipped             = local.skipped
    # BFF ADAPTERS_JSON ([{family,url}]) - feed into deploy-core-* settings.adapters.
    adapters_json = jsonencode([for f, a in local.adapters : { family = f, url = a.url } if a.url != null])
    endpoints     = { for f, a in local.adapters : "hello-dbadapter-${f}" => a.url if a.url != null }
    idle_behavior = { for f, a in local.adapters : "hello-dbadapter-${f}" => { scale_to_zero = a.scale_to_zero } }
    deploy_steps = concat(
      [for f, a in module.appsvc : {
        kind           = "webapp-zip"
        app            = "hello-dbadapter-${f}"
        resource_id    = a.id
        name           = a.name
        resource_group = var.platform_appservice.resource_group_name
        package_uri    = try(var.artifacts[local.artifact].package_url, null)
        package_sha256 = try(var.artifacts[local.artifact].package_sha256, null)
        slot           = a.staging_slot
      }],
      [for f, e in azurerm_virtual_machine_scale_set_extension.sqlvm_adapter : {
        kind           = "vmss-update-instances"
        app            = "hello-dbadapter-${f}"
        resource_id    = local.uniform_vmss.id
        name           = local.uniform_vmss.name
        resource_group = var.platform_vmss.resource_group_name
        package_uri    = try(var.artifacts[local.artifact].package_url, null)
        package_sha256 = try(var.artifacts[local.artifact].package_sha256, null)
        slot           = null
      }],
    )
    rollback = {
      method = "per-hosting"
      how    = "ACA: re-apply previous digest (single revision mode) | App Service: swap the staging slot back | VMSS Uniform: re-apply previous package version (model update) + az vmss update-instances"
    }
  }
}
