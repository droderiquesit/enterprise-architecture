output "id" {
  description = "Web app resource id."
  value       = local.app_id
}

output "name" {
  description = "Web app name."
  value       = var.name
}

output "hostname" {
  description = "Default hostname (<name>.azurewebsites.net)."
  value       = local.hostname
}

output "url" {
  description = "https://<default hostname>."
  value       = "https://${local.hostname}"
}

output "staging_slot" {
  description = "Staging slot name when created (deploy target for swap-based releases), else null."
  value       = local.slot ? "staging" : null
}

output "private" {
  description = "True when the app is reachable only through its private endpoint."
  value       = local.private
}

output "app_settings" {
  description = "Effective app settings (plain values and dsv:// references)."
  value       = local.settings
}
