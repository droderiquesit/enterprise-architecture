module "sidecar_config" {
  source       = "../fluent-bit"
  role         = "sidecar"
  datadog_site = var.datadog.site
}

module "sidecar_forward_config" {
  source       = "../fluent-bit"
  role         = "sidecar-forward"
  datadog_site = var.datadog.site
}

# Observability Pipelines mode: sidecars forward to the Worker's fluent source (no API key / shared key on the edge)
module "sidecar_op_config" {
  source          = "../fluent-bit"
  role            = "sidecar"
  datadog_site    = var.datadog.site
  log_destination = "observability_pipelines"
  op_endpoint     = { host = coalesce(local.op_endpoint_host, "unset"), port = local.op_endpoint_port }
}

locals {
  agg_fqdn = local.agg_enabled ? try(azapi_resource.aggregator[0].output.fqdn, null) : null
  gw_fqdn  = local.gw_enabled ? try(azapi_resource.gateway[0].output.fqdn, null) : null

  otlp_grpc_endpoint = local.gw_enabled ? "http://${local.gw_fqdn}:4317" : var.gateway.external_endpoints.grpc_endpoint
  otlp_http_endpoint = local.gw_enabled ? "https://${local.gw_fqdn}" : var.gateway.external_endpoints.http_endpoint

  forward_host = local.op_mode ? local.op_endpoint_host : (local.agg_enabled ? local.agg_fqdn : try(var.aggregator.external_endpoint.host, null))
  forward_port = local.op_mode ? local.op_endpoint_port : (local.agg_enabled ? 24224 : try(var.aggregator.external_endpoint.port, 24224))

  # service-agnostic env defaults per runtime (service-specific values come from modules/instrumentation)
  runtime_env = {
    common = {
      DD_SITE                     = var.datadog.site
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      OTEL_TRACES_SAMPLER         = "parentbased_traceidratio"
      OTEL_TRACES_SAMPLER_ARG     = "1"
      OTEL_LOGS_EXPORTER          = "none"
      OTEL_PROPAGATORS            = "tracecontext,baggage"
      OTEL_EXPORTER_OTLP_TIMEOUT  = "10000"
      OTEL_BSP_MAX_QUEUE_SIZE     = "2048"
    }
    dotnet = {
      OTEL_DOTNET_AUTO_LOGS_ENABLED = "false"
    }
    python = {
      OTEL_PYTHON_LOG_CORRELATION                      = "true"
      OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED = "false"
      OTEL_PYTHON_EXCLUDED_URLS                        = "healthz,readyz,version"
    }
    browser = {
      DD_SITE = var.datadog.site
    }
    # Datadog tracers of managed runtimes (modules/instrumentation apm.method = agent_gateway)
    apm_gateway = local.apm_url == null ? {} : { DD_TRACE_AGENT_URL = local.apm_url }
    # lab-wide fleet switches read by modules/instrumentation
    fleet = {
      EH_LOG_PIPELINE      = local.log_pipeline
      EH_APM_MODE          = try(module.fleet.sections.apm.mode, "datadog")
      EH_PROFILING_ENABLED = tostring(try(module.fleet.sections.profiling.enabled, true))
    }
  }

  contract = {
    datadog_site = var.datadog.site
    api_key_ref  = var.datadog.api_key_ref
    secrets = {
      provider    = "delinea-dsv"
      tenant      = var.secrets.tenant
      tld         = var.secrets.tld
      base_url    = local.dsv_base_url
      auth        = var.secrets.auth
      fetch_image = var.secrets.fetch_image
      env_file    = "/dsv-secrets/fluentbit-env.yaml"
    }
    otlp = {
      grpc_endpoint            = local.otlp_grpc_endpoint
      http_endpoint            = local.otlp_http_endpoint
      headers_ref              = try(var.gateway.auth.client_headers_ref, null)
      default_protocol         = "http/protobuf"
      node_agent_grpc_port     = 4317
      node_agent_http_port     = 4318
      host_agent_grpc_endpoint = "http://localhost:4317"
      gateway_distribution     = local.gw_enabled ? var.gateway.distribution : "external"
      internal_only            = true
      logs_policy              = local.gw_enabled ? var.gateway.otlp_logs : "drop"
    }
    fluentbit = {
      forward_host           = local.forward_host
      forward_port           = local.forward_port
      forward_tls            = local.op_mode ? false : var.aggregator.forward_tls != null
      forward_shared_key_ref = local.op_mode ? null : var.aggregator.forward_shared_key_ref
      sidecar_image          = var.images.fluent_bit
      sidecar_config         = module.sidecar_config.main_config
      sidecar_forward_config = local.op_mode ? module.sidecar_op_config.main_config : module.sidecar_forward_config.main_config
      sidecar_parsers        = local.flb_parsers
      sidecar_lua            = local.flb_lua
      sidecar_mode           = local.op_mode ? "forward" : var.sidecar_mode
      logs_intake_host       = local.intake_host
      metrics_port           = 2020
      aca_console_allow      = var.aca_console_allow
    }
    event_hub = local.eh_enabled ? {
      namespace_id          = local.eh_namespace_id
      authorization_rule_id = local.eh_send_rule_id
      app_logs_hub          = var.event_hub.app_logs_hub
      platform_logs_hub     = var.event_hub.platform_logs_hub
      activity_logs_hub     = local.activity_hub
      kafka_endpoint        = "${local.eh_fqdn}:9093"
      consumer_group        = var.event_hub.consumer_group
      location              = var.location
    } : null
    env = local.runtime_env
    log_routes = {
      aks        = "daemonset"
      vm         = "host"
      vmss       = "host"
      aca        = "sidecar"
      aci        = "sidecar"
      appservice = local.eh_enabled ? "eventhub" : "none"
      functions  = local.eh_enabled ? "eventhub" : "none"
      logicapp   = local.eh_enabled ? "eventhub" : "none"
    }
    # log aggregation tier: kind = observability_pipelines (Worker) | fluent_bit (aggregator)
    aggregator = {
      hosting           = local.op_mode ? local.opv.hosting : var.aggregator.hosting
      kind              = local.op_mode ? "observability_pipelines" : "fluent_bit"
      resource_id       = local.op_mode ? (local.op_hosted ? azapi_resource.op_worker[0].id : null) : (local.agg_enabled ? azapi_resource.aggregator[0].id : null)
      fqdn              = local.forward_host
      pipeline_id       = local.pipeline_id
      agent_logs_url    = local.op_mode && local.forward_host != null ? "http://${local.forward_host}:8282" : null
      log_pipeline      = local.log_pipeline
      eventhub_consumer = local.op_mode ? "observability-pipelines" : var.event_hub.consumer_group
    }
    gateway = {
      hosting     = var.gateway.hosting
      resource_id = local.gw_enabled ? azapi_resource.gateway[0].id : null
      fqdn        = local.gw_fqdn
      sampling    = var.gateway.sampling
      # Datadog Agent APM gateway (Datadog tracers of managed runtimes)
      apm = {
        hosting     = var.apm_gateway.hosting
        resource_id = local.apm_hosted ? azapi_resource.apm_gateway[0].id : null
        url         = local.apm_url
      }
    }
    collector_identity_principal_id = try(var.collector_identity.principal_id, null)
  }
}

output "contract" {
  description = "obs-telemetry-transport v3 contract (catalog/contracts/obs-telemetry-transport.v3.schema.json). No secrets: DSV references only."
  value       = local.contract
}

output "event_hub_namespace_id" {
  description = "Id of the Event Hubs namespace (created or existing)."
  value       = local.eh_namespace_id
}

output "diagnostics_authorization_rule_id" {
  description = "Namespace authorization rule id for azurerm_monitor_diagnostic_setting.eventhub_authorization_rule_id."
  value       = local.eh_send_rule_id
}

output "aggregator_id" {
  description = "Id of the Fluent Bit aggregator Container App (null in Observability Pipelines mode or when not hosted here)."
  value       = local.agg_enabled ? azapi_resource.aggregator[0].id : null
}

output "op_worker_id" {
  description = "Id of the Observability Pipelines Worker Container App (null when not hosted here)."
  value       = local.op_hosted ? azapi_resource.op_worker[0].id : null
}

output "op_pipeline_id" {
  description = "Id of the Observability Pipelines pipeline the Worker runs."
  value       = local.pipeline_id
}

output "apm_gateway_id" {
  description = "Id of the Datadog Agent APM gateway Container App (null when not hosted here)."
  value       = local.apm_hosted ? azapi_resource.apm_gateway[0].id : null
}

output "gateway_id" {
  description = "Id of the OTel gateway Container App (null when not hosted here)."
  value       = local.gw_enabled ? azapi_resource.gateway[0].id : null
}

output "gateway_args" {
  description = "Collector command-line (config providers) - useful when hosting the gateway yourself."
  value       = local.gw_args
}

output "generated_secrets" {
  description = <<-EOT
    Secret VALUES generated by Azure in this apply that must be stored in Delinea DSV (sensitive; read by
    tools/secrets/publish.py, never printed): eventhub-fluentbit-listen = Listen-rule connection string
    (event_hub.mode = create). The aggregator reads it back from DSV at event_hub.listen_connection_string_ref.
  EOT
  sensitive   = true
  value = local.eh_create ? {
    "eventhub-fluentbit-listen" = azurerm_eventhub_namespace_authorization_rule.fluentbit_listen[0].primary_connection_string
  } : {}
}
