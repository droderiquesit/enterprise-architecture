# obs-azure-integration publishes no contract.
output "integration_id" {
  description = "datadog_integration_azure id (app_registration) or the Microsoft.Datadog/monitors id (native); null for none."
  value       = module.integration.integration_id
}

output "mode" {
  description = "Integration mode in effect (modules/azure-integration mode)."
  value       = module.integration.mode
}

output "native_log_forwarding" {
  description = "Logs forwarded by the Azure Native integration (empty unless mode = native with native_logs on)."
  value       = module.integration.native_log_forwarding
}
