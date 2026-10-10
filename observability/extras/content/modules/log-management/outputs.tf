output "index_name" {
  description = "Name of the Azure logs index (null when index.enabled = false)."
  value       = var.index.enabled ? datadog_logs_index.azure[0].name : null
}

output "metric_names" {
  description = "Log-based metric names (empty when metrics are disabled)."
  value       = sort([for m in datadog_logs_metric.this : m.name])
}

output "dashboard_url" {
  description = "URL of the Azure logs dashboard (null when dashboard.enabled = false)."
  value       = var.dashboard.enabled ? datadog_dashboard_json.azure_logs[0].url : null
}

output "pipeline_id" {
  description = "Id of the Activity Log processing pipeline (null when pipeline.enabled = false)."
  value       = var.pipeline.enabled ? datadog_logs_custom_pipeline.activity[0].id : null
}

output "archive_id" {
  description = "Id of the Azure Storage log archive (null when archive.enabled = false)."
  value       = var.archive.enabled ? datadog_logs_archive.azure[0].id : null
}

output "log_metric_queries" {
  description = "metric suffix -> log query (documentation / verification)."
  value       = { for k, m in local.log_metrics : k => m.query }
}
