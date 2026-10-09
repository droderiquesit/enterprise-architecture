mock_provider "datadog" {
  mock_resource "datadog_dashboard_json" {
    defaults = { url = "/dashboard/abc-def-ghi" }
  }
}

variables {
  env = "dev"
}

run "defaults_touch_nothing_but_the_dashboard" {
  command = plan
  assert {
    condition     = length(datadog_logs_index.azure) == 0 && length(datadog_logs_index_order.this) == 0 && length(datadog_logs_custom_pipeline.activity) == 0 && length(datadog_logs_metric.this) == 0 && length(datadog_logs_archive.azure) == 0
    error_message = "Index, order, pipeline, metrics and archive are opt-in (orgs that manage them elsewhere are untouched)."
  }
  assert {
    condition     = length(datadog_dashboard_json.azure_logs) == 1 && jsondecode(datadog_dashboard_json.azure_logs[0].dashboard).title == "[dev] Azure platform logs"
    error_message = "Dashboard by default."
  }
  assert {
    condition     = length(jsondecode(datadog_dashboard_json.azure_logs[0].dashboard).widgets[0].definition.widgets) == 10
    error_message = "7 timeseries + 2 log streams + note (no Entra widgets unless dashboard.entra)."
  }
}

run "everything_enabled" {
  command = plan
  variables {
    index = {
      enabled     = true
      daily_limit = 2000000
      exclusion_filters = [
        { name = "appgw-2xx", query = "source:azure.network @category:ApplicationGatewayAccessLog @properties.httpStatus:200", sample_rate = 0.5 },
      ]
    }
    index_order = { manage = true, indexes = ["azure-platform", "main"] }
    pipeline    = { enabled = true }
    metrics     = { enabled = true }
    archive = {
      enabled         = true
      storage_account = "stlogarchive"
      container       = "datadog"
      client_id       = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "00000000-0000-0000-0000-000000000000"
    }
    dashboard = { entra = true }
  }
  assert {
    condition     = datadog_logs_index.azure[0].filter[0].query == "source:azure* -azure_log_type:application" && datadog_logs_index.azure[0].retention_days == 15 && datadog_logs_index.azure[0].daily_limit == 2000000
    error_message = "Index filter, retention, quota."
  }
  assert {
    condition     = length(datadog_logs_index.azure[0].exclusion_filter) == 4 && datadog_logs_index.azure[0].exclusion_filter[0].filter[0].sample_rate == 0.9 && datadog_logs_index.azure[0].daily_limit_reset[0].reset_time == "00:00"
    error_message = "Default sampled exclusions (AKS full-audit reads, storage reads, Cosmos data plane) + custom ones."
  }
  assert {
    condition     = jsonencode(datadog_logs_index_order.this[0].indexes) == jsonencode(["azure-platform", "main"])
    error_message = "Index order is explicit and opt-in."
  }
  assert {
    condition     = length(datadog_logs_metric.this) == 8 && datadog_logs_metric.this["keyvault.access_denied"].name == "azure.logs.keyvault.access_denied" && length(datadog_logs_metric.this["activity.deletes"].group_by) == 2
    error_message = "Log-based metrics with bounded group-bys."
  }
  assert {
    condition     = alltrue([for p in datadog_logs_custom_pipeline.activity[0].processor : p.attribute_remapper[0].preserve_source && !p.attribute_remapper[0].override_on_conflict])
    error_message = "Pipeline never removes or overrides attributes (out-of-the-box pipelines keep working)."
  }
  assert {
    condition     = datadog_logs_archive.azure[0].azure_archive[0].storage_account == "stlogarchive" && datadog_logs_archive.azure[0].query == "source:azure* -azure_log_type:application"
    error_message = "Archive to an existing storage account."
  }
  assert {
    condition     = length(jsondecode(datadog_dashboard_json.azure_logs[0].dashboard).widgets[0].definition.widgets) == 12
    error_message = "Entra widgets added on request."
  }
}

run "reject_index_order_without_index" {
  command = plan
  variables {
    index       = { enabled = true }
    index_order = { manage = true, indexes = ["main"] }
  }
  expect_failures = [datadog_logs_index_order.this[0]]
}

run "reject_archive_without_target" {
  command = plan
  variables {
    archive = { enabled = true }
  }
  expect_failures = [var.archive]
}

run "reject_bad_retention" {
  command = plan
  variables {
    index = { enabled = true, retention_days = 10 }
  }
  expect_failures = [var.index]
}
