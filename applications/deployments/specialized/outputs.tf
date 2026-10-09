output "contract" {
  description = "deploy-specialized contract v1 (catalog/contracts/deploy-specialized.v1.schema.json). No secrets."
  value = {
    component    = local.component
    architecture = "specialized"
    service_fabric = local.sf_enabled ? {
      cluster_id           = local.sf.cluster_id
      cluster_name         = local.sf.cluster_name
      management_host      = trimprefix(local.sf.management_endpoint, "https://")
      application_type     = "HelloInventoryAppType"
      application_version  = local.sf_type_version
      application_name     = "fabric:/hello-inventory"
      service_manifest     = local.sf_service_manifest
      application_manifest = local.sf_app_manifest
      package_uri          = try(var.artifacts["svc-inventory-api"].package_url, null)
      package_sha256       = try(var.artifacts["svc-inventory-api"].package_sha256, null)
      deploy_script        = "applications/deployments/specialized/scripts/deploy-sf.sh"
    } : null
    aro = local.aro_enabled ? {
      cluster_id    = local.aro.cluster_id
      api_server    = local.aro.api_server_url
      namespace     = var.settings.aro_namespace
      deploy_script = "applications/deployments/specialized/scripts/deploy-aro.sh"
      helm = {
        release    = "hello-catalog-api"
        chart      = "hello-service"
        chart_path = "applications/charts/hello-service"
        values     = yamlencode(local.aro_values) # no secrets: existing-Secret references only
      }
    } : null
    apps = merge(
      local.sf_enabled ? { "hello-inventory-api-sf" = {
        id           = local.sf.cluster_id, name = local.sf.cluster_name, type = "Microsoft.ServiceFabric/managedClusters", service = "hello-inventory-api"
        architecture = "service-fabric-managed", app_log_route = "host", sidecar = false, url = null, urls = { public = null, private = null }
        health_path  = "/healthz", readiness_path = "/readyz", version_path = "/version", scale_to_zero = false, min_replicas = 1, max_replicas = 1
        version      = local.inv_version, image = null, identity_name = "hello-inventory-api"
      } } : {},
      local.aro_enabled ? { "hello-catalog-api-aro" = {
        id           = local.aro.cluster_id, name = local.aro.cluster_name, type = "Microsoft.RedHatOpenShift/openShiftClusters", service = "hello-catalog-api"
        architecture = "aro", app_log_route = "daemonset", sidecar = false, url = null, urls = { public = null, private = null }
        health_path  = "/healthz", readiness_path = "/readyz", version_path = "/version", scale_to_zero = false, min_replicas = var.settings.aro_replicas, max_replicas = var.settings.aro_replicas
        version      = local.cat_version, image = try(var.artifacts["svc-catalog-api"].image, null), identity_name = null
      } } : {},
      local.cvm_enabled ? { "hello-worker-cvm" = {
        id           = local.cvm.id, name = local.cvm.name, type = "Microsoft.Compute/virtualMachines", service = "hello-worker"
        architecture = "vm-confidential", app_log_route = "host", sidecar = false, url = null, urls = { public = null, private = null }
        health_path  = "/healthz", readiness_path = "/readyz", version_path = null, scale_to_zero = false, min_replicas = 1, max_replicas = 1
        version      = lookup(local.artifact_version, "svc-worker", "unknown"), image = null, identity_name = local.cvm.workload
      } } : {},
      local.automation != null ? { "hello-health-probe" = {
        id           = azurerm_automation_runbook.health_probe[0].id, name = azurerm_automation_runbook.health_probe[0].name, type = "Microsoft.Automation/automationAccounts/runbooks", service = "hello-health-probe"
        architecture = "automation", app_log_route = "none", sidecar = false, url = null, urls = { public = null, private = null }
        health_path  = null, readiness_path = null, version_path = null, scale_to_zero = true, min_replicas = 0, max_replicas = 0
        version      = "1", image = null, identity_name = try(local.automation.identity, null)
      } } : {},
    )
    endpoints     = {}
    idle_behavior = {}
    status = {
      service_fabric = local.sf_enabled ? "implemented" : "disabled"
      aro            = local.aro_ready ? "implemented" : (local.aro_enabled ? "blocked: needs foundation-identity hello-catalog-api and a digest-pinned svc-catalog-api image" : "blocked")
      confidential   = local.cvm_enabled ? "implemented" : (local.cvm != null ? "blocked: foundation-identity contract not provided" : "disabled")
      automation     = local.automation != null ? "implemented" : "disabled"
    }
    rollback = {
      method = "per-platform"
      how    = "SF: sfctl application upgrade to the previous type version (monitored upgrade auto-rolls back on health failure) | ARO: helm rollback hello-catalog-api -n <ns> / re-apply previous digest | CVM: re-apply previous package | runbook: re-apply previous commit"
    }
  }
}
