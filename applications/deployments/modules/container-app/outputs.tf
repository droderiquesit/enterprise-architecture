output "id" {
  value = azurerm_container_app.this.id
}

output "name" {
  value = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Ingress FQDN (null without ingress). Internal apps resolve only inside the environment/VNet."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "url" {
  value = try("https://${azurerm_container_app.this.ingress[0].fqdn}", null)
}

output "latest_revision_name" {
  value = azurerm_container_app.this.latest_revision_name
}

output "revision_suffix" {
  description = "Suffix of the revision this apply creates (use as previous_revision_suffix to roll back to it later)."
  value       = var.revisions.mode == "Multiple" ? local.revision_suffix : null
}

output "has_sidecar" {
  value = local.has_sidecar
}

output "scale_to_zero" {
  value = var.scale.min_replicas == 0
}

output "container_names" {
  description = "Container names in the template (app first, then sidecars)."
  value       = [for c in azurerm_container_app.this.template[0].container : c.name]
}

output "secret_refs" {
  description = "Container Apps secrets backed by Key Vault: secret name -> versionless secret id (never values)."
  value       = { for k, s in local.secrets : k => s.key_vault_secret_id if s.key_vault_secret_id != null }
}

output "plain_env" {
  description = "Non-secret env of the app container (for tests/inspection)."
  value       = var.env
}
