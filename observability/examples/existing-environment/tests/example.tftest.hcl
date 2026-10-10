# Run after ./vendor.sh. Mock providers only; nothing is contacted.
mock_provider "datadog" {
  override_during = plan
  mock_resource "datadog_observability_pipeline" {
    defaults = { id = "aaaaaaaa-0000-0000-0000-000000000001" }
  }
  mock_resource "datadog_rum_application" {
    defaults = { id = "bbbbbbbb-0000-0000-0000-000000000002", client_token = "pub0123456789abcdef0123456789abcdef" }
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
mock_provider "helm" {}
mock_provider "kubernetes" {}

run "connects_existing_resources_verbatim" {
  command = plan

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
    condition     = output.resources["orders-web/app"].app_logs == "eventhub" && output.resources["orders-api/cluster"].app_logs == "datadog_agent" && output.resources["orders-api/cluster"].apm == "ssi_kubernetes"
    error_message = "One authoritative collector per signal: App Service logs via Event Hubs, AKS pods via the node Agent, SSI on AKS"
  }
  assert {
    condition     = output.resources["orders-web/app"].scope_tags["team"] == "orders" && output.resources["orders-web/app"].scope_tags["service"] == "orders-web"
    error_message = "Platform logs of a resource carry its owner's tag-policy tags"
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
    condition     = length(output.diagnostic_settings.activity_log) == 1 && output.diagnostic_settings.entra == null && output.diagnostic_settings.tiers["orders-api/db"] == "standard"
    error_message = "Activity Log of the supplied subscription exported; Entra off; standard tier"
  }
  assert {
    condition     = output.observability_pipeline_id == "aaaaaaaa-0000-0000-0000-000000000001" && yamldecode(module.kubernetes[0].op_worker_values).datadog.pipelineId == "aaaaaaaa-0000-0000-0000-000000000001"
    error_message = "Observability Pipelines pipeline created; Worker on the existing AKS cluster"
  }
  assert {
    condition     = length(module.azure_integration) == 1
    error_message = "Azure integration expected"
  }
  assert {
    condition     = output.instrumentation["orders-web"].env["FAULTS_ENABLED"] == "false" && output.instrumentation["orders-web"].app_settings != null && output.instrumentation["orders-api"].k8s_patch != null
    error_message = "instrumentation settings for the owners expected; fault injection disabled"
  }
  assert {
    condition     = output.instrumentation["orders-api"].tags["team"] == "orders" && output.instrumentation["orders-api"].tags["tier"] == "critical" && output.instrumentation["orders-api"].tags["version"] == "4.2.0"
    error_message = "Instrumentation carries the tag-policy tags of the rendered service"
  }
  assert {
    condition     = output.rum.browser_config["orders-web"].sessionReplaySampleRate == 0 && contains(output.rum.browser_config["orders-web"].allowedTracingUrls[0].propagatorTypes, "tracecontext")
    error_message = "RUM: session replay off, datadog + tracecontext propagation to first-party APIs"
  }
}

run "fluent_bit_direct" {
  command = plan
  variables {
    observability_pipelines = { enabled = false }
    telemetry = {
      datadog_site = "datadoghq.com"
      api_key_ref  = "dsv://monitoring/prod/datadog-api-key#value"
      secrets      = { tenant = "contoso", base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "acrplatformprod.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://otel-gateway.observability.internal:4317", http_endpoint = "http://otel-gateway.observability.internal:4318" }
      fluentbit    = { forward_host = "fluent-bit-aggregator.observability.internal", forward_port = 24224, sidecar_mode = "datadog" }
      env          = { fleet = { EH_LOG_PIPELINE = "fluent_bit_direct", EH_APM_MODE = "otel", EH_PROFILING_ENABLED = "false" } }
    }
  }
  assert {
    condition     = output.observability_pipeline_id == null && yamldecode(module.kubernetes[0].op_worker_values).datadog.pipelineId == "unset"
    error_message = "fluent_bit_direct: no pipeline, no Worker"
  }
}

run "fault_injection_cannot_be_enabled" {
  command = plan
  variables {
    fault_injection_enabled = true
  }
  expect_failures = [var.fault_injection_enabled]
}

run "dbm_cluster_checks" {
  command = plan
  variables {
    dbm = { enabled = true }
  }
  assert {
    condition     = output.dbm["orders-postgresql"].hosting == "cluster_checks" && output.dbm["orders-postgresql"].password_source == "dsv"
    error_message = "DBM runs as cluster checks with a DSV password reference (ENC[dsv://...])"
  }
}
