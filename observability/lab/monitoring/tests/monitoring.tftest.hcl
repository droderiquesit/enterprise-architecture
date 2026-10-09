mock_provider "datadog" {
  mock_resource "datadog_service_level_objective" {
    defaults = { id = "0123456789abcdef0123456789abcdef" }
  }
  mock_resource "datadog_dashboard_json" {
    defaults = { url = "/dashboard/abc-def-ghi" }
  }
}

variables {
  environment = {
    name      = "dev", location = "swedencentral", subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id = "00000000-0000-0000-0000-000000000000", name_prefix = "eh", owner = "platform-team@example.com"
    team      = "platform-engineering", cost_center = "lab-0001", expires_on = "2026-12-31", tags = {}
  }
  obs_prereqs = {
    datadog_site = "datadoghq.com"
    rum          = { applications = { "hello-frontend" = { application_id = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb", name = "eh-dev-hello-frontend" } } }
  }
}

run "nothing_deployed_onboards_nothing" {
  command = plan

  assert {
    condition     = length(output.summary.services) == 0 && output.summary.monitor_count == 0
    error_message = "without contracts no service is present"
  }
}

run "minimal_profile_slice" {
  command = plan

  variables {
    contract_references = {
      "obs-telemetry-transport.otlp.grpc_endpoint" = "http://otel-gateway.internal:4317"
      "deploy-frontend.url"                        = "https://eh-dev-frontend.azurestaticapps.net"
      "deploy-core-aca.apps.hello-bff.url"         = "https://hello-bff.example.swedencentral.azurecontainerapps.io"
      "deploy-core-aca.apps.hello-bff.id"          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-apps-dev/providers/Microsoft.App/containerApps/ca-hello-bff"
      "deploy-core-aca.apps.hello-orders-api.url"  = "https://hello-orders-api.internal.example.azurecontainerapps.io"
      "deploy-core-aca.apps.hello-catalog-api.url" = "https://hello-catalog-api.internal.example.azurecontainerapps.io"
      "deploy-durable.function_app.id"             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-apps-dev/providers/Microsoft.Web/sites/func-hello-durable"
      "platform-db-sql.databases.orders.id"        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-sql-dev/providers/Microsoft.Sql/servers/sql-eh-dev/databases/orders"
      "platform-db-sql.databases.fulfillment.id"   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-sql-dev/providers/Microsoft.Sql/servers/sql-eh-dev/databases/fulfillment"
      "platform-db-postgresql.server.id"           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-pg-dev/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-eh-dev"
      "platform-messaging.namespace_id"            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-msg-dev/providers/Microsoft.ServiceBus/namespaces/sb-eh-dev"
      "deploy-partner-sim.url"                     = "http://10.41.8.4:8080"
      "deploy-jobs.jobs.seed.id"                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-apps-dev/providers/Microsoft.App/jobs/caj-seed"
    }
  }

  assert {
    condition = output.summary.services == tolist(["hello-bff", "hello-catalog-api", "hello-durable", "hello-frontend",
    "hello-jobs", "hello-orders-api", "hello-partner-sim", "telemetry-pipeline"])
    error_message = "the minimal-profile slice must be onboarded"
  }
  assert {
    condition     = contains(output.summary.skipped_services, "hello-dbadapter-mysql") && contains(output.summary.skipped_services, "hello-worker")
    error_message = "undeployed services must be skipped"
  }
  assert {
    condition     = contains(keys(module.onboarding.monitor_ids), "hello-durable/queue.backlog@servicebus") && contains(keys(module.onboarding.monitor_ids), "hello-orders-api/sql.connection_failures@orders-db")
    error_message = "resource monitors expected for resolved resources"
  }
  assert {
    condition     = contains(keys(module.onboarding.monitor_ids), "telemetry-pipeline/pipeline.canary_logs_missing")
    error_message = "pipeline canary monitor expected"
  }
  assert {
    condition     = contains(keys(module.onboarding.synthetic_test_ids), "hello-frontend/site/browser")
    error_message = "frontend browser journey expected"
  }
  assert {
    condition     = contains(output.synthetics_skipped, "hello-orders-api/internal")
    error_message = "private endpoints are skipped without a private location"
  }
}
