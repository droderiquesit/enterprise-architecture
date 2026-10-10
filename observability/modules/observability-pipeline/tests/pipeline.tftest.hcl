mock_provider "datadog" {
  mock_resource "datadog_observability_pipeline" {
    defaults = { id = "aaaaaaaa-0000-0000-0000-000000000001" }
  }
}

variables {
  name         = "eh-dev-logs"
  env          = "dev"
  datadog_site = "datadoghq.eu"
  default_tags = { region = "swedencentral", managed_by = "terraform", application = "enterprise-hello" }
  secret_refs = {
    api_key                    = "dsv://eh/dev/datadog-api-key#value"
    eventhub_connection_string = "dsv://eh/dev/eventhub-fluentbit-listen#value"
  }
  eventhub_bootstrap = "eh-evhns-obs-dev.servicebus.windows.net:9093"
  sources = {
    eventhub = { topics = ["app-logs", "platform-logs", "activity-logs"] }
  }
  azure = {
    aca_console_allow = ["eh-caj-*"]
    scope_tags        = { "/subscriptions/00000000-0000-0000-0000-000000000000/" = { env = "dev" } }
    sample_categories = { AppServiceHTTPLogs = 25 }
    daily_quota_bytes = 10737418240
  }
}

run "full_pipeline_graph" {
  command = plan
  assert {
    condition     = length(datadog_observability_pipeline.this.config[0].source) == 3 && datadog_observability_pipeline.this.config[0].pipeline_type == "logs"
    error_message = "fluent + agent + eventhubs sources"
  }
  assert {
    condition     = one([for s in datadog_observability_pipeline.this.config[0].source : s.kafka[0].sasl[0].mechanism if s.id == "eventhubs"]) == "PLAIN" && one([for s in datadog_observability_pipeline.this.config[0].source : s.kafka[0].librdkafka_option[0].value if s.id == "eventhubs"]) == "sasl_ssl"
    error_message = "Event Hubs Kafka: SASL PLAIN over SSL"
  }
  assert {
    condition     = toset([for g in datadog_observability_pipeline.this.config[0].processor_group : g.id]) == toset(["app", "azure"])
    error_message = "app + azure processor groups"
  }
  assert {
    condition     = toset(flatten([for g in datadog_observability_pipeline.this.config[0].processor_group : [for p in g.processor : p.id] if g.id == "azure"])) == toset(["azure-unwrap", "azure-split", "azure-shape", "azure-drop-duplicates", "azure-dedupe", "azure-sample-appservicehttplogs", "azure-quota", "azure-tags"])
    error_message = "azure processors: unwrap, split, shape, drop, dedupe, sample, quota, tags"
  }
  assert {
    condition     = one([for d in datadog_observability_pipeline.this.config[0].destination : d.datadog_logs[0].buffer[0].disk[0].when_full if d.id == "datadog-logs"]) == "block"
    error_message = "disk buffer with backpressure"
  }
  assert {
    condition     = output.worker_env["DD_OP_SOURCE_KAFKA_SASL_USERNAME"] == "$ConnectionString" && output.worker_env["DD_OP_SOURCE_FLUENT_ADDRESS"] == "0.0.0.0:24224" && output.worker_env["DD_OP_API_ADDRESS"] == "0.0.0.0:8686"
    error_message = "worker env contract"
  }
  assert {
    condition     = output.worker_secret_refs["DD_OP_SOURCE_KAFKA_SASL_PASSWORD"] == "dsv://eh/dev/eventhub-fluentbit-listen#value" && !contains(keys(output.worker_env), "DD_API_KEY")
    error_message = "secrets only as DSV references"
  }
  assert {
    condition     = strcontains(output.vrl.tags, "\"region\":\"swedencentral\"") && strcontains(output.vrl.azure_shape, "\"aca_allow\":[\"eh-caj-*\"]") && strcontains(output.vrl.azure_shape, "/subscriptions/00000000-0000-0000-0000-000000000000\"")
    error_message = "VRL configs carry the tag defaults, ACA allow list, scope tags (trailing slash trimmed)"
  }
}

run "fluent_and_agent_only" {
  command = plan
  variables {
    sources = {}
  }
  assert {
    condition     = length(datadog_observability_pipeline.this.config[0].processor_group) == 1 && !contains(keys(output.worker_env), "DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS")
    error_message = "no Event Hub: no azure group, no kafka env"
  }
}

run "archive_requires_secret" {
  command = plan
  variables {
    archive = { enabled = true }
  }
  expect_failures = [datadog_observability_pipeline.this]
}

run "reject_literal_secret" {
  command = plan
  variables {
    secret_refs = { api_key = "0123456789abcdef" }
  }
  expect_failures = [var.secret_refs]
}
