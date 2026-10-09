# obs-azure-integration publishes no contract.
output "integration_id" {
  value = module.integration.integration_id
}

output "mode" {
  value = module.integration.mode
}

output "azure_logs_dashboard_url" {
  value = module.log_management.dashboard_url
}

output "azure_log_metrics" {
  value = module.log_management.metric_names
}

output "native_log_forwarding" {
  description = "Logs forwarded by the Azure Native integration (empty unless mode = native with native_logs on)."
  value       = module.integration.native_log_forwarding
}
