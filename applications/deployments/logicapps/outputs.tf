output "contract" {
  description = "deploy-logicapps contract v1 (catalog/contracts/deploy-logicapps.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "logic-apps"
    resource_group_name = azurerm_resource_group.this.name
    workflows = merge(
      local.consumption ? { consumption = { id = azurerm_logic_app_workflow.batch_request[0].id, name = azurerm_logic_app_workflow.batch_request[0].name, connection_id = azapi_resource.servicebus_connection[0].id } } : {},
      local.standard ? { standard = { id = azurerm_logic_app_standard.archive[0].id, name = azurerm_logic_app_standard.archive[0].name, connection_id = null } } : {},
    )
    apps = merge(
      local.consumption ? { "hello-logicapps-consumption" = {
        id          = azurerm_logic_app_workflow.batch_request[0].id, name = azurerm_logic_app_workflow.batch_request[0].name, type = "Microsoft.Logic/workflows"
        service     = local.svc, architecture = "logic-apps-consumption", app_log_route = "eventhub", sidecar = false, url = null, urls = { public = null, private = null }
        health_path = null, readiness_path = null, version_path = null, scale_to_zero = true, min_replicas = 0, max_replicas = 0
        version     = lookup(local.artifact_version, local.meta.artifact, "n/a"), image = null, identity_name = local.svc
      } } : {},
      local.standard ? { "hello-logicapps-standard" = {
        id          = azurerm_logic_app_standard.archive[0].id, name = azurerm_logic_app_standard.archive[0].name, type = "Microsoft.Web/sites"
        service     = local.svc, architecture = "logic-apps-standard", app_log_route = module.env[0].log_route, sidecar = false
        url         = "https://${azurerm_logic_app_standard.archive[0].default_hostname}", urls = { public = local.private ? null : "https://${azurerm_logic_app_standard.archive[0].default_hostname}", private = "https://${azurerm_logic_app_standard.archive[0].default_hostname}" }
        health_path = null, readiness_path = null, version_path = null, scale_to_zero = false, min_replicas = 1, max_replicas = 1
        version     = lookup(local.artifact_version, local.meta.artifact, "n/a"), image = null, identity_name = local.svc
      } } : {},
    )
    endpoints     = {}
    idle_behavior = merge(local.consumption ? { "hello-logicapps-consumption" = { scale_to_zero = true } } : {}, local.standard ? { "hello-logicapps-standard" = { scale_to_zero = false } } : {})
    deploy_steps = local.standard ? [{
      kind           = "logicapp-zip"
      app            = "hello-logicapps-standard"
      resource_id    = azurerm_logic_app_standard.archive[0].id
      name           = azurerm_logic_app_standard.archive[0].name
      resource_group = local.as.resource_group_name
      package_uri    = try(var.artifacts[local.meta.artifact].package_url, null)
      package_sha256 = try(var.artifacts[local.meta.artifact].package_sha256, null)
      slot           = null
    }] : []
    rollback = {
      method = "redeploy-previous"
      how    = "Consumption: re-apply previous commit (definition is Terraform-managed); Standard: re-run deploy-zip.sh with the previous svc-logicapps package"
    }
  }
}
