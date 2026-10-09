output "ids" {
  description = "SLO key -> SLO id."
  value       = { for k, s in datadog_service_level_objective.this : k => s.id }
}

output "burn_rate_monitor_ids" {
  description = "Burn-rate alert key -> monitor id."
  value       = { for k, m in datadog_monitor.burn_rate : k => m.id }
}
