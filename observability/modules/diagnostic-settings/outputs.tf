output "app_log_settings" {
  description = "resource key -> app-log categories exported to the app-logs hub."
  value       = local.app_settings
}

output "platform_log_settings" {
  description = "resource key -> platform categories exported to the platform-logs hub."
  value       = local.platform_settings
}

output "excluded_app_log_resources" {
  description = "Resources whose app-log categories are deliberately NOT exported (collected by sidecar/daemonset/host)."
  value       = sort([for k, r in var.resources : k if r.app_log_route != "eventhub"])
}

output "unsupported_resources" {
  description = "Resources skipped because their type is not in the category maps (no diagnostic setting created)."
  value       = local.unsupported
}

output "resource_types" {
  value = local.resource_types
}
