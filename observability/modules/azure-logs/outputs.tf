output "activity_log_settings" {
  description = "subscription id (lower case) -> diagnostic setting id of the Activity Log export."
  value       = { for s, d in azurerm_monitor_diagnostic_setting.activity_log : s => d.id }
}

output "activity_log_categories" {
  description = "Activity Log categories exported (sorted; empty when activity_log.enabled = false)."
  value       = var.activity_log.enabled ? sort(var.activity_log.categories) : []
}

output "entra_setting_id" {
  description = "Tenant-level Entra diagnostic setting id (null when disabled)."
  value       = var.entra.enabled ? azurerm_monitor_aad_diagnostic_setting.entra[0].id : null
}

output "log_forwarding" {
  description = "What this module exports through Event Hubs; pass it to modules/azure-integration eventhub_log_forwarding to keep the native path exclusive."
  value = {
    activity_log_subscription_ids = sort(keys(local.activity_subscriptions))
    entra_enabled                 = var.entra.enabled
    destination_hub               = var.destination.eventhub_name
  }
}
