# obs-diagnostics publishes no contract (no consumers); outputs are evidence for the deployment record.
output "app_log_settings" {
  value = module.diagnostics.app_log_settings
}

output "platform_log_settings" {
  value = module.diagnostics.platform_log_settings
}

output "excluded_app_log_resources" {
  value = module.diagnostics.excluded_app_log_resources
}

output "unsupported_resources" {
  value = module.diagnostics.unsupported_resources
}

output "discovered_targets" {
  description = "Diagnostic targets derived from discovered contracts + explicit resources (key -> id, route)."
  value       = { for k, t in local.all_targets : k => { id = t.id, app_log_route = t.app_log_route } }
}

output "aca_eventhub_apps" {
  description = "Container Apps/Jobs whose console logs travel via the environment diagnostic setting (must match fluentbit.aca_console_allow)."
  value       = local.aca_eventhub_apps
}

output "platform_log_tiers" {
  description = "Effective platform-log tier per target."
  value       = module.diagnostics.platform_log_tiers
}

output "activity_log_settings" {
  description = "Subscription -> Activity Log diagnostic setting id."
  value       = module.azure_logs.activity_log_settings
}

output "entra_setting_id" {
  value = module.azure_logs.entra_setting_id
}

output "control_plane_log_forwarding" {
  description = "What is exported through Event Hubs (input for the native-integration exclusivity check of obs-azure-integration)."
  value       = module.azure_logs.log_forwarding
}
