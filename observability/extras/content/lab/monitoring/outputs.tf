# obs-monitoring has no downstream consumers (no `contract` output); these outputs feed the deployment record.
output "summary" {
  description = "Onboarded / skipped services, dropped optional references, object counts."
  value       = module.onboarding.summary
}

output "dashboard_urls" {
  description = "URLs of the service and overview dashboards."
  value       = module.onboarding.dashboard_urls
}

output "synthetics_skipped" {
  description = "Synthetic tests skipped (with the reason) instead of created."
  value       = module.onboarding.synthetics_skipped
}
