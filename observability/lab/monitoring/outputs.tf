# obs-monitoring has no downstream consumers (no `contract` output); these outputs feed the deployment record.
output "summary" {
  description = "Onboarded / skipped services, dropped optional references, object counts."
  value       = module.onboarding.summary
}

output "dashboard_urls" {
  value = module.onboarding.dashboard_urls
}

output "synthetics_skipped" {
  value = module.onboarding.synthetics_skipped
}
