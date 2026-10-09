output "onboarding" {
  description = "Onboarded services, dropped optional references, object counts."
  value       = module.onboarding.summary
}

output "resources" {
  description = "Monitored Azure resources (ids exactly as supplied) and their Datadog scopes."
  value       = module.onboarding.resources
}

output "dashboards" {
  value = module.onboarding.dashboard_urls
}

output "instrumentation" {
  description = "Per service: log route, non-secret env, secret env references, App Service settings / Kubernetes patch. Hand these to the application owners."
  value = {
    for k, m in module.instrumentation : k => {
      log_route    = m.log_route
      env          = merge(m.env, { FAULTS_ENABLED = tostring(var.fault_injection_enabled) })
      secret_env   = m.secret_env
      app_settings = var.instrumented_services[k].architecture == "appservice" ? m.app_settings : null
      k8s_patch    = var.instrumented_services[k].architecture == "aks" ? m.k8s_patch : null
    }
  }
}

output "diagnostic_settings" {
  description = "Diagnostic settings created (app-log and platform-log) and resources without supported categories."
  value = var.diagnostics.enabled ? {
    app_logs      = module.diagnostics[0].app_log_settings
    platform_logs = module.diagnostics[0].platform_log_settings
    unsupported   = module.diagnostics[0].unsupported_resources
  } : null
}

output "dbm" {
  description = "DBM configuration per database (no secrets) incl. the setup SQL the DBA must run."
  value       = var.dbm.enabled ? module.dbm[0].configured : null
}
