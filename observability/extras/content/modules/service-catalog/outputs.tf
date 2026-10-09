output "entity_ids" {
  description = "Service name -> catalog entity id."
  value       = merge({ for k, e in datadog_software_catalog.service : k => e.id }, { for k, e in datadog_software_catalog.system : "system:${k}" => e.id })
}

output "entities_yaml" {
  description = "Rendered entity YAML (review/tests)."
  value       = { for k, v in local.entities : k => yamlencode(v) }
}
