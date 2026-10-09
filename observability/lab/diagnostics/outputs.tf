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
