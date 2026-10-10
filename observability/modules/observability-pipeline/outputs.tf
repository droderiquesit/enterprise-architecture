output "pipeline_id" {
  description = "Observability Pipelines pipeline id (DD_OP_PIPELINE_ID of every Worker of this pipeline)."
  value       = datadog_observability_pipeline.this.id
}

output "ports" {
  description = "Worker listen ports: fluent (Fluent Bit forward), datadog_agent, otlp_grpc, otlp_http, api (health /health, tap/top)."
  value       = { fluent = 24224, datadog_agent = 8282, otlp_grpc = 4317, otlp_http = 4318, api = 8686 }
}

output "worker_env" {
  description = "Non-secret Worker environment (bootstrap + source addresses). The Worker's data dir must be persistent for disk buffers."
  value = merge(
    {
      DD_OP_PIPELINE_ID   = datadog_observability_pipeline.this.id
      DD_SITE             = var.datadog_site
      DD_OP_API_ENABLED   = "true"
      DD_OP_API_ADDRESS   = "0.0.0.0:8686"
      DD_OP_DATA_DIR_BASE = "/var/lib/observability-pipelines-worker"
      DD_OP_TAGS          = "env:${var.env},service:observability-pipelines-worker"
      DD_OP_LOG_FORMAT    = "json"
    },
    var.sources.fluent_bit ? { DD_OP_SOURCE_FLUENT_ADDRESS = "0.0.0.0:24224" } : {},
    var.sources.datadog_agent ? { DD_OP_SOURCE_DATADOG_AGENT_ADDRESS = "0.0.0.0:8282" } : {},
    var.sources.opentelemetry ? { DD_OP_SOURCE_OTEL_GRPC_ADDRESS = "0.0.0.0:4317", DD_OP_SOURCE_OTEL_HTTP_ADDRESS = "0.0.0.0:4318" } : {},
    local.eh ? {
      DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS = var.eventhub_bootstrap
      DD_OP_SOURCE_KAFKA_SASL_USERNAME     = "$ConnectionString"
    } : {},
  )
}

output "worker_secret_refs" {
  description = "Worker secret env NAME -> Delinea DSV reference (resolved by dsv-fetch into the worker's ephemeral dotenv file; never values)."
  value = merge(
    { DD_API_KEY = var.secret_refs.api_key },
    local.eh ? { DD_OP_SOURCE_KAFKA_SASL_PASSWORD = var.secret_refs.eventhub_connection_string } : {},
    var.archive.enabled ? { DD_OP_DESTINATION_DATADOG_ARCHIVES_AZURE_BLOB_CONNECTION_STRING = var.secret_refs.archive_connection_string } : {},
  )
}

output "vrl" {
  description = "Rendered VRL programs (custom processors) - tests run them with the vector CLI."
  value       = local.vrl
}

output "agent_logs_url_path" {
  description = "Datadog Agent setting DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL = http://<worker host>:8282."
  value       = ":8282"
}

output "worker_command" {
  description = <<-EOT
    Container command of the Worker (image datadog/observability-pipelines-worker): waits (fail closed, 120 s) for the
    dsv-fetch dotenv file with the secrets (DD_API_KEY, Kafka SASL password, archive connection string), sources it,
    gives every replica its own data dir under DD_OP_DATA_DIR_BASE (disk buffers; the Worker requires one directory per
    instance) and execs the Worker.
  EOT
  value       = ["/bin/sh", "-c", local.worker_script]
}

output "secrets_file" {
  description = "Path of the dsv-fetch dotenv file the worker command sources (dsv-fetch init --format dotenv --dotenv-name opw.env --out /dsv-secrets)."
  value       = "/dsv-secrets/opw.env"
}
