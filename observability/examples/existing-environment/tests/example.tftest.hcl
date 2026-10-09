# Run after ./vendor.sh. Mock providers only; nothing is contacted.
mock_provider "datadog" {
  mock_resource "datadog_service_level_objective" {
    defaults = { id = "0123456789abcdef0123456789abcdef" }
  }
  mock_resource "datadog_dashboard_json" {
    defaults = { url = "/dashboard/abc-def-ghi" }
  }
}

mock_provider "azurerm" {
  mock_data "azurerm_monitor_diagnostic_categories" {
    defaults = {
      log_category_types = ["AppServiceConsoleLogs", "AppServiceAppLogs", "AppServiceHTTPLogs", "AppServicePlatformLogs", "PostgreSQLLogs", "kube-audit-admin"]
    }
  }
}

mock_provider "azapi" {}

run "onboards_existing_resources_verbatim" {
  command = plan

  assert {
    condition     = output.onboarding.services == tolist(["orders-api", "orders-web", "telemetry-pipeline"])
    error_message = "all manifests must be onboarded"
  }
  assert {
    condition     = output.resources["orders-web/app"].id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders-prod/providers/Microsoft.Web/sites/app-orders-web-prod"
    error_message = "App Service id must be used verbatim"
  }
  assert {
    condition     = output.resources["orders-api/db"].id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-orders-prod"
    error_message = "PostgreSQL id must be used verbatim"
  }
  assert {
    condition     = output.resources["orders-api/cluster"].id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-prod/providers/Microsoft.ContainerService/managedClusters/aks-prod-weu"
    error_message = "AKS id must be used verbatim"
  }
  assert {
    condition     = contains(keys(module.onboarding.monitor_ids), "orders-api/pg.cpu@db") && contains(keys(module.onboarding.monitor_ids), "orders-web/appsvc.http_5xx_ratio@app") && contains(keys(module.onboarding.monitor_ids), "orders-api/k8s.replicas_unavailable")
    error_message = "App Service, AKS and PostgreSQL monitors expected"
  }
  assert {
    condition     = length(output.onboarding.dropped_optional) == 0
    error_message = "no references in an existing-environment root"
  }
  assert {
    condition     = contains(keys(module.diagnostics[0].app_log_settings), "orders-web/app") && !contains(keys(module.diagnostics[0].app_log_settings), "orders-api/db")
    error_message = "only the App Service (eventhub route) exports application logs"
  }
  assert {
    condition     = contains(keys(module.diagnostics[0].platform_log_settings), "orders-api/db")
    error_message = "PostgreSQL platform logs exported"
  }
  assert {
    condition     = length(module.azure_integration) == 1
    error_message = "Azure integration expected"
  }
  assert {
    condition     = output.instrumentation["orders-web"].env["FAULTS_ENABLED"] == "false"
    error_message = "fault injection disabled"
  }
  assert {
    condition     = output.instrumentation["orders-api"].k8s_patch != null && output.instrumentation["orders-web"].app_settings != null
    error_message = "instrumentation patches for the owners expected"
  }
}

run "fault_injection_cannot_be_enabled" {
  command = plan
  variables {
    fault_injection_enabled = true
  }
  expect_failures = [var.fault_injection_enabled]
}
