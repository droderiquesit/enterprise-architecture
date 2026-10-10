output "schedule_id" {
  description = "Fleet Automation schedule id (null when disabled)."
  value       = local.enabled ? datadog_fleet_schedule.this[0].id : null
}
