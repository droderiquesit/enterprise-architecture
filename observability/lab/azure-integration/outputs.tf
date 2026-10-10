# obs-azure-integration publishes no contract.
output "integration_id" {
  value = module.integration.integration_id
}

output "mode" {
  value = module.integration.mode
}

output "native_log_forwarding" {
  description = "Logs forwarded by the Azure Native integration (empty unless mode = native with native_logs on)."
  value       = module.integration.native_log_forwarding
}
