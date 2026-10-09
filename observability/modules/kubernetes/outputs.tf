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
      logs_enabled          = false
      cluster_checks        = true
    }
    fluent_bit = {
      namespace           = local.fb_ns
      daemonset           = "fluent-bit"
      excluded_namespaces = var.fluent_bit.exclude_namespaces
      opt_out_annotation  = "fluentbit.io/exclude"
    }
    log_route = "daemonset"
    charts = {
      datadog    = var.charts.datadog_version
      fluent_bit = var.charts.fluent_bit_version
      agent_tag  = var.charts.agent_tag
    }
    # dsv mode: the chart Secret "datadog" holds only the ENC[dsv://...] reference; existing: the synced Secret
    api_key_secret_name = local.dsv_mode ? local.release : var.api_key.secret_name
  }
}

output "contract" {
  description = "obs-kubernetes v1 contract (catalog/contracts/obs-kubernetes.v1.schema.json)."
  value       = local.contract
}

output "datadog_values" {
  description = "Rendered Datadog chart values (no secrets)."
  value       = yamlencode(local.datadog_values)
}

output "fluent_bit_values" {
  value = yamlencode(local.fluent_bit_values)
}
