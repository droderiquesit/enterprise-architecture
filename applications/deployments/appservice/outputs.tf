output "contract" {
  description = "deploy-appservice contract v1 (catalog/contracts/deploy-appservice.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "app-service"
    resource_group_name = local.rg
    apps = {
      for k, a in module.app : k => {
        id             = a.id
        name           = a.name
        type           = "Microsoft.Web/sites"
        service        = local.apps[k].svc
        architecture   = local.apps[k].arch
        app_log_route  = module.env[k].log_route
        sidecar        = false
        url            = a.url
        urls           = { public = a.private ? null : a.url, private = a.url }
        health_path    = "/healthz"
        readiness_path = "/readyz"
        version_path   = "/version"
        scale_to_zero  = false
        min_replicas   = 1
        max_replicas   = 1
        version        = local.artifact_version[local.meta[local.apps[k].svc].artifact]
        image          = local.apps[k].mode == "container" ? try(var.artifacts[local.meta[local.apps[k].svc].artifact].image, null) : null
        identity_name  = local.apps[k].svc
        staging_slot   = a.staging_slot
      }
    }
    endpoints     = { for k, a in module.app : k => a.url }
    idle_behavior = { for k in keys(module.app) : k => { scale_to_zero = false } }
    deploy_steps = [for k, a in module.app : {
      kind           = "webapp-zip"
      app            = k
      resource_id    = a.id
      name           = a.name
      resource_group = local.rg
      package_uri    = try(var.artifacts[local.meta[local.apps[k].svc].artifact].package_url, null)
      package_sha256 = try(var.artifacts[local.meta[local.apps[k].svc].artifact].package_sha256, null)
      slot           = a.staging_slot
    } if local.apps[k].mode == "code"]
    rollback = {
      method = "slot-swap"
      how    = "code apps: deploy-zip.sh deploys to the staging slot, smoke-tests it and swaps; rollback = `az webapp deployment slot swap --slot staging` again (previous build is in staging). Containers: re-apply the previous digest (or swap)."
    }
  }
}
