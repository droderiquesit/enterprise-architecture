output "id" {
  description = "Container app resource id."
  value       = azurerm_container_app.this.id
}

output "name" {
  description = "Container app name."
  value       = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Ingress FQDN (null without ingress). Internal apps resolve only inside the environment/VNet."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "url" {
  description = "https://<ingress fqdn> (null without ingress)."
  value       = try("https://${azurerm_container_app.this.ingress[0].fqdn}", null)
}

output "latest_revision_name" {
  description = "Name of the latest revision."
  value       = azurerm_container_app.this.latest_revision_name
}

output "revision_suffix" {
  description = "Suffix of the revision this apply creates (use as previous_revision_suffix to roll back to it later)."
  value       = var.revisions.mode == "Multiple" ? local.revision_suffix : null
}

output "has_sidecar" {
  description = "True when the observability sidecar patch added containers."
  value       = local.has_sidecar
}

output "scale_to_zero" {
  description = "True when min_replicas = 0 (idle behaviour for monitoring)."
  value       = var.scale.min_replicas == 0
}

output "container_names" {
  description = "Container names in the template (app first, then sidecars)."
  value       = [for c in azurerm_container_app.this.template[0].container : c.name]
}

output "secret_refs" {
  description = "Settings whose value is a Delinea DSV reference: name -> dsv:// (resolved by the app; never values)."
  value       = { for k, v in var.env : k => v if startswith(v, "dsv://") }
}

output "init_container_names" {
  description = "Init containers (dsv-fetch for the sidecar's key, Consumption profile)."
  value       = [for c in local.inits : c.name]
}

output "dsv_fetch_mode" {
  description = "How the sidecar's key is fetched: init (Consumption profile), refresher (Dedicated profile: regular container), none."
  value       = length(local.inits) > 0 ? "init" : (length(local.refreshers) > 0 ? "refresher" : "none")
}

output "plain_env" {
  description = "Env of the app container (plain values and dsv:// references; for tests/inspection)."
  value       = var.env
}
