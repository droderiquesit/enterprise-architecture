output "plan" {
  description = "Key -> collection plan {id, type, kind, metrics, platform_logs, app_logs, log_destination, agent, apm, dbm, scope_tags}."
  value       = local.plan
}

output "diagnostic_targets" {
  description = "Input for modules/diagnostic-settings `resources` (resources with policy categories; app-log export only for the eventhub route)."
  value = { for k, p in local.plan : k => {
    id            = p.id
    app_log_route = p.app_logs == "eventhub" ? "eventhub" : (contains(["fluent_bit_sidecar"], p.app_logs) ? "sidecar" : "none")
    platform_logs = true
    tier          = var.resources[k].tier
  } if p.platform_logs == "diagnostic_settings" }
}

output "scope_tags" {
  description = "Lowercase resource id -> Datadog tags (Observability Pipelines azure.scope_tags / Fluent Bit aggregator FLB_AZURE_SCOPE_TAGS)."
  value       = { for k, p in local.plan : lower(p.id) => p.scope_tags if length(p.scope_tags) > 0 }
}

output "dbm_candidates" {
  description = "Resources eligible for Database Monitoring (modules/dbm needs host / auth per database in addition)."
  value       = { for k, p in local.plan : k => p.id if p.dbm }
}

output "matrix" {
  description = "Sorted rows for the per-resource collection matrix (docs / reports)."
  value       = [for k in sort(keys(local.plan)) : merge({ key = k }, { for f in ["type", "kind", "metrics", "platform_logs", "app_logs", "log_destination", "agent", "apm"] : f => tostring(local.plan[k][f]) }, { dbm = tostring(local.plan[k].dbm) })]
}
