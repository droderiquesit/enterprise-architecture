output "contract" {
  description = "deploy-core-aca contract v1 (catalog/contracts/deploy-core-aca.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "container-apps-consumption"
    resource_group_name = azurerm_resource_group.this.name
    environment_id      = local.aca.environment_id
    apps = {
      for k, a in module.app : k => {
        id              = a.id
        name            = a.name
        type            = "Microsoft.App/containerApps"
        service         = k
        architecture    = "aca"
        app_log_route   = module.env[k].log_route
        sidecar         = a.has_sidecar
        url             = a.url
        urls            = { public = k == "hello-bff" && local.external ? a.url : null, private = a.url }
        health_path     = "/healthz"
        readiness_path  = "/readyz"
        version_path    = "/version"
        scale_to_zero   = a.scale_to_zero
        min_replicas    = local.apps[k].min_replicas
        max_replicas    = local.apps[k].max_replicas
        version         = local.artifact_version[local.meta[k].artifact]
        image           = try(var.artifacts[local.meta[k].artifact].image, null)
        revision_suffix = a.revision_suffix
        identity_name   = k
      }
    }
    # Smoke convention (tools/smoke/smoke.py): base URLs serving /healthz, /readyz and /version.
    endpoints = { for k, a in module.app : k => a.url }
    public_api = {
      origin    = try(module.app["hello-bff"].url, null)
      base_path = "/api"
      external  = local.external
    }
    idle_behavior = { for k, a in module.app : k => { scale_to_zero = a.scale_to_zero } }
    rollback = {
      method = "traffic-shift"
      how    = "set settings.traffic.<svc> = {latest_weight = 0, previous_revision_suffix = <apps.<svc>.revision_suffix of the last good apply>} and re-apply, or `az containerapp ingress traffic set` (break-glass)"
    }
  }
}
