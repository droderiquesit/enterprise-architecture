output "integration_id" {
  description = "datadog_integration_azure id (app_registration) or the Microsoft.Datadog/monitors id (native); null for none."
  value       = var.mode == "app_registration" ? datadog_integration_azure.this[0].id : local.native_monitor_id
}

output "mode" {
  value = var.mode
}

output "metric_host_filters" {
  description = "Effective Datadog host_filters string (app_registration)."
  value       = local.tag_filter_string
}
