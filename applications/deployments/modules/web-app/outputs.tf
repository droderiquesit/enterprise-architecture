output "id" {
  value = local.app_id
}

output "name" {
  value = var.name
}

output "hostname" {
  value = local.hostname
}

output "url" {
  value = "https://${local.hostname}"
}

output "staging_slot" {
  description = "Staging slot name when created (deploy target for swap-based releases), else null."
  value       = local.slot ? "staging" : null
}

output "private" {
  value = local.private
}

output "app_settings" {
  value = local.settings
}
