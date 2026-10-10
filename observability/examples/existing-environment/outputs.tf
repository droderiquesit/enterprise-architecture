output "resources" {
  description = "Connected Azure resources (ids exactly as supplied) and their collection plan per signal (fleet inventory)."
  value       = module.fleet.plan
}

output "collection_matrix" {
  description = "Per-resource collection matrix: metrics, platform logs, application logs, log destination, Agent, APM."
  value       = module.fleet.matrix
}

output "observability_pipeline_id" {
  description = "Observability Pipelines pipeline id (DD_OP_PIPELINE_ID of the Worker on AKS)."
  value       = local.op_enabled ? module.observability_pipeline[0].pipeline_id : null
}

output "rum" {
  description = "RUM applications and the browser SDK init settings (propagatorTypes datadog + tracecontext, replay off) for the frontend owners."
  value       = length(var.rum) > 0 ? { applications = module.rum[0].applications, browser_config = module.rum[0].browser_config } : null
}

output "instrumentation" {
  description = "Per service: tags, log route, APM / profiling method, non-secret env, secret env references, App Service settings / Kubernetes patch and what the application image must contain. Hand these to the application owners."
  value = {
    for k, m in module.instrumentation : k => {
      tags             = m.tags
      azure_tags       = m.azure_tags
      log_route        = m.log_route
      apm              = m.apm
      profiling        = m.profiling
      app_requirements = m.app_requirements
      env              = merge(m.env, { FAULTS_ENABLED = tostring(var.fault_injection_enabled) })
      secret_env       = m.secret_env
      app_settings     = local.by_service[k].architecture == "appservice" ? m.app_settings : null
      k8s_patch        = local.by_service[k].architecture == "aks" ? m.k8s_patch : null
    }
  }
}

output "diagnostic_settings" {
  description = "Diagnostic settings created (app-log and platform-log) and resources without supported categories."
  value = var.diagnostics.enabled ? {
    app_logs      = module.diagnostics[0].app_log_settings
    platform_logs = module.diagnostics[0].platform_log_settings
    unsupported   = module.diagnostics[0].unsupported_resources
    tiers         = module.diagnostics[0].platform_log_tiers
    activity_log  = module.azure_logs[0].activity_log_settings
    entra         = module.azure_logs[0].entra_setting_id
  } : null
}

output "dbm" {
  description = "DBM configuration per database (no secrets) incl. the setup SQL the DBA must run."
  value       = var.dbm.enabled ? module.dbm[0].configured : null
}
