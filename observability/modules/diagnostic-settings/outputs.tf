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
  description = "Resource type of each input resource (provider namespace + child types, lower case), by key."
  value       = local.resource_types
}

output "platform_log_tiers" {
  description = "resource key -> effective platform-log tier (security | standard | verbose)."
  value       = local.effective_tier
}

output "self_referencing_resources" {
  description = "Resources skipped because they ARE the destination Event Hubs namespace (would stream into itself)."
  value       = local.self_referencing
}
