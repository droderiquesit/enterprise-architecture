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

locals {
  agg_fqdn = local.agg_enabled ? try(azapi_resource.aggregator[0].output.fqdn, null) : null
  gw_fqdn  = local.gw_enabled ? try(azapi_resource.gateway[0].output.fqdn, null) : null

  otlp_grpc_endpoint = local.gw_enabled ? "http://${local.gw_fqdn}:4317" : var.gateway.external_endpoints.grpc_endpoint
  otlp_http_endpoint = local.gw_enabled ? "https://${local.gw_fqdn}" : var.gateway.external_endpoints.http_endpoint

  forward_host = local.agg_enabled ? local.agg_fqdn : var.aggregator.external_endpoint.host
  forward_port = local.agg_enabled ? 24224 : var.aggregator.external_endpoint.port

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
  }

  contract = {
    datadog_site      = var.datadog.site
    api_key_secret_id = var.datadog.api_key_secret_id
    otlp = {
      grpc_endpoint            = local.otlp_grpc_endpoint
      http_endpoint            = local.otlp_http_endpoint
      headers_secret_id        = try(var.gateway.auth.client_headers_secret_id, null)
      default_protocol         = "http/protobuf"
      node_agent_grpc_port     = 4317
      node_agent_http_port     = 4318
      host_agent_grpc_endpoint = "http://localhost:4317"
      gateway_distribution     = local.gw_enabled ? var.gateway.distribution : "external"
      internal_only            = true
      logs_policy              = local.gw_enabled ? var.gateway.otlp_logs : "drop"
    }
    fluentbit = {
      forward_host                 = local.forward_host
      forward_port                 = local.forward_port
      forward_tls                  = var.aggregator.forward_tls != null
      forward_shared_key_secret_id = var.aggregator.forward_shared_key_secret_id
      sidecar_image                = var.images.fluent_bit
      sidecar_config               = module.sidecar_config.main_config
      sidecar_forward_config       = module.sidecar_forward_config.main_config
      sidecar_parsers              = local.flb_parsers
      sidecar_lua                  = local.flb_lua
      sidecar_mode                 = var.sidecar_mode
      logs_intake_host             = local.intake_host
      metrics_port                 = 2020
    }
    event_hub = local.eh_enabled ? {
      namespace_id          = local.eh_namespace_id
      authorization_rule_id = local.eh_send_rule_id
      app_logs_hub          = var.event_hub.app_logs_hub
      platform_logs_hub     = var.event_hub.platform_logs_hub
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
    aggregator = {
      hosting     = var.aggregator.hosting
      resource_id = local.agg_enabled ? azapi_resource.aggregator[0].id : null
      fqdn        = local.forward_host
    }
    gateway = {
      hosting     = var.gateway.hosting
      resource_id = local.gw_enabled ? azapi_resource.gateway[0].id : null
      fqdn        = local.gw_fqdn
      sampling    = var.gateway.sampling
    }
    collector_identity_principal_id = try(var.collector_identity.principal_id, null)
  }
}

output "contract" {
  description = "obs-telemetry-transport v1 contract (catalog/contracts/obs-telemetry-transport.v1.schema.json). No secrets."
  value       = local.contract
}

output "event_hub_namespace_id" {
  value = local.eh_namespace_id
}

output "diagnostics_authorization_rule_id" {
  description = "Namespace authorization rule id for azurerm_monitor_diagnostic_setting.eventhub_authorization_rule_id."
  value       = local.eh_send_rule_id
}

output "aggregator_id" {
  value = local.agg_enabled ? azapi_resource.aggregator[0].id : null
}

output "gateway_id" {
  value = local.gw_enabled ? azapi_resource.gateway[0].id : null
}

output "gateway_args" {
  description = "Collector command-line (config providers) - useful when hosting the gateway yourself."
  value       = local.gw_args
}
