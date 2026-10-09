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

output "native_log_forwarding" {
  description = "What the native integration forwards (input for modules/azure-logs native_log_forwarding); empty outside mode = native."
  value = {
    subscription_log_subscription_ids = var.mode == "native" && try(var.native.send_subscription_logs, false) ? sort([for s in var.subscription_ids : lower(s)]) : []
    resource_log_subscription_ids     = var.mode == "native" && try(var.native.send_resource_logs, false) ? sort([for s in var.subscription_ids : lower(s)]) : []
    aad_logs                          = var.mode == "native" && try(var.native.send_aad_logs, false)
  }
}
