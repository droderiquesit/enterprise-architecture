locals {
  contract = {
    cluster_name = var.cluster_name
    namespace    = local.dd_ns
    agent = {
      daemonset             = local.release
      local_service         = "${local.release}.${local.dd_ns}.svc.cluster.local"
      host_ip_env           = "DD_AGENT_HOST"
      otlp_grpc_port        = 4317
      otlp_http_port        = 4318
      apm_port              = 8126
      dogstatsd_port        = 8125
      otlp_endpoint_grpc    = "http://$(DD_AGENT_HOST):4317"
      otlp_endpoint_http    = "http://$(DD_AGENT_HOST):4318"
      cluster_agent_service = "${local.release}-cluster-agent.${local.dd_ns}.svc.cluster.local"
      logs_enabled          = local.agent_logs
      logs_destination      = local.agent_logs ? (local.op_mode ? local.op_logs_url : "datadog") : null
      ssi_enabled           = local.apm_datadog
      ssi_namespaces        = local.apm_datadog ? var.apm.namespaces : []
      cluster_checks        = true
    }
    fluent_bit = {
      enabled             = local.fluent_bit_on
      namespace           = local.fb_ns
      daemonset           = "fluent-bit"
      excluded_namespaces = var.fluent_bit.exclude_namespaces
      opt_out_annotation  = "fluentbit.io/exclude"
    }
    log_route     = "daemonset"
    log_pipeline  = module.fleet.log_pipeline
    log_collector = local.agent_logs ? "datadog-agent" : "fluent-bit"
    charts = {
      datadog    = var.charts.datadog_version
      fluent_bit = var.charts.fluent_bit_version
      agent_tag  = local.agent_version
    }
    # the chart Secret "datadog" holds only the ENC[dsv://...] reference (never the key)
    api_key_secret_name = local.release
  }
}

output "contract" {
  description = "obs-kubernetes v2 contract (catalog/contracts/obs-kubernetes.v2.schema.json)."
  value       = local.contract
}

output "datadog_values" {
  description = "Datadog chart values layers exactly as passed to helm_release.datadog (no secrets): [0] values/base.yaml, [1] the computed fleet layer, [2..] values_overrides."
  value       = local.datadog_values
}

output "datadog_postrender_args" {
  description = "Arguments of postrender/dsv-fetch-init.sh (adds the dsv-fetch-install init container); for helm template reproductions."
  value       = helm_release.datadog.postrender.args
}

output "fluent_bit_values" {
  value = yamlencode(local.fluent_bit_values)
}

output "op_worker_values" {
  description = "Rendered observability-pipelines-worker chart values (op_worker.enabled)."
  value       = yamlencode(local.opw_values)
}
