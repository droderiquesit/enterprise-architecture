output "ids" {
  description = "Monitor key -> Datadog monitor id."
  value       = { for k, m in datadog_monitor.this : k => m.id }
}

output "messages" {
  description = "Final notification messages (for review/tests)."
  value       = local.messages
}

output "datadog_monitor_queries" {
  description = "Monitor key -> final query (review/tests)."
  value       = { for k, m in var.monitors : k => m.query }
}
