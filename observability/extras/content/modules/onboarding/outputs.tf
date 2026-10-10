output "summary" {
  description = "What was onboarded, skipped and dropped. Fails the plan on unresolved required references or malformed resource ids."
  value = {
    services         = sort(keys(local.present))
    skipped_services = local.skipped_services
    dropped_optional = local.dropped_optional
    monitor_count    = length(local.monitors)
    slo_count        = length(local.slos)
    synthetic_count  = length(local.synthetic_tests)
  }

  precondition {
    condition     = !var.strict_references || length(local.missing_required) == 0
    error_message = "Unresolved REQUIRED references: ${join("; ", local.missing_required)}. Provide them in contract_references or mark the resource/endpoint required: false."
  }
  precondition {
    condition     = length(local.invalid_ids) == 0
    error_message = "Resource ids are not Azure resource ids: ${join("; ", local.invalid_ids)}."
  }
}

output "resources" {
  description = "Resolved resources: '<service>/<role>' -> {id, type, scope}. Ids are used verbatim."
  value       = { for k, r in local.resources : k => { id = r.id, type = r.type, scope = r.scope } }
}

output "monitor_ids" {
  description = "Monitor ids by monitor key."
  value       = module.monitors.ids
}

output "slo_ids" {
  description = "SLO ids by SLO key."
  value       = module.slos.ids
}

output "burn_rate_monitor_ids" {
  description = "Burn-rate monitor ids by SLO key."
  value       = module.slos.burn_rate_monitor_ids
}

output "synthetic_test_ids" {
  description = "API and browser synthetic test ids by test key."
  value       = merge(module.synthetics.api_test_ids, module.synthetics.browser_test_ids)
}

output "synthetics_skipped" {
  description = "Synthetic tests skipped (with the reason) instead of created."
  value       = module.synthetics.skipped
}

output "dashboard_urls" {
  description = "Service dashboard URLs by service, plus the overview dashboard (key overview)."
  value       = merge(module.dashboards.service_dashboard_urls, { overview = module.dashboards.overview_url })
}

output "catalog_entity_ids" {
  description = "Software Catalog entity ids by service."
  value       = module.catalog.entity_ids
}
