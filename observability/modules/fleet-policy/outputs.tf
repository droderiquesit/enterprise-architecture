output "log_pipeline" {
  description = "observability_pipelines | fluent_bit_direct."
  value       = local.log_pipeline
}

output "node_collector" {
  description = "Where the Datadog Agent runs (AKS nodes, VMs): agent (Agent collects logs -> OP Worker) | fluent_bit. fluent_bit_direct implies fluent_bit."
  value       = local.log_pipeline == "fluent_bit_direct" ? "fluent_bit" : try(local.section.logs.node_collector, "agent")
}

output "apm" {
  description = "Effective APM decision: requested/effective mode, method (ssi_kubernetes | ssi_host | agent_gateway | serverless_init | otlp_agent | otlp_gateway | none), fallback reason, library versions, sample rate."
  value = {
    requested_mode   = local.requested
    mode             = local.effective_mode
    method           = local.method
    fallback_reason  = local.fallback_reason
    library_versions = try(local.apm.library_versions, {})
    sample_rate      = local.sample_rate
    logs_injection   = try(local.apm.logs_injection, true)
    dbm_propagation  = local.dbm_mode
    data_streams     = length(local.dsm_env) > 0
  }
}

output "apm_env" {
  description = "Datadog tracer env for datadog mode (SDK switch TELEMETRY_SDK=datadog + OTEL_SDK_DISABLED, log injection, sampling, DBM propagation, DSM). Empty otherwise."
  value       = local.apm_env
}

output "profiling" {
  description = "Effective Continuous Profiler decision {enabled, reason (when not enabled), env}."
  value = {
    requested = local.profiling_requested
    enabled   = local.profiling_enabled
    supported = local.profiler_supported
    preview   = local.otel_preview
    reason    = local.profiling_reason
    env       = local.profiling_env
  }
}

output "agent" {
  description = "Agent fleet settings (version, remote configuration / updates, optional products, upgrade schedule)."
  value       = local.section.agent
}

output "op_worker" {
  description = "Observability Pipelines Worker sizing / version."
  value       = local.section.op_worker
}

output "rum" {
  description = "RUM browser SDK settings."
  value       = local.section.rum
}

output "policy" {
  description = "The decoded policy in use."
  value       = local.policy
}
