output "log_pipeline" {
  description = "observability_pipelines | fluent_bit_direct."
  value       = local.log_pipeline
}

output "node_collector" {
  description = "Where the Datadog Agent runs (AKS nodes, VMs): agent (Agent collects logs -> OP Worker / intake) | fluent_bit (AKS: the Fluent Bit DaemonSet; fluent_bit_direct or logs.node_collector = fluent_bit). VM / VMSS hosts are always agent. (3.x output; log_collector is the per-architecture decision.)"
  value = local.host_arch ? "agent" : local.fb_direct ? "fluent_bit" : (
    local.arch == "aks" ? (local.log_collector == "agent" ? "agent" : "fluent_bit") : (local.legacy_node == "fluent_bit" ? "fluent_bit" : "agent")
  )
}

output "log_collector" {
  description = "Effective application-log collector: agent | agent_sidecar (ACI) | serverless_init (Container Apps) | azure (diagnostic settings -> Event Hubs) | fluent_bit | fluent_bit_sidecar (fluent_bit_direct on ACA / ACI) | none."
  value       = local.log_collector
}

output "log_collector_reason" {
  description = "Why log_collector differs from the requested logs.collector (unsupported for the architecture, or fluent_bit_direct); null otherwise."
  value       = local.log_collector_reason
}

output "agent_image" {
  description = "Pinned Datadog Agent image <agent.image>:<agent.version> (null when the policy has no agent.image / agent.version)."
  value       = local.agent_image
}

output "agent_sidecar" {
  description = "ACI Datadog Agent sidecar: image (single pin) and sizing (agent.sidecar)."
  value = {
    image     = local.agent_image
    cpu       = try(local.agent_s.sidecar.cpu, 0.25)
    memory_gb = try(local.agent_s.sidecar.memory_gb, 0.5)
  }
}

output "serverless_init" {
  description = "Container Apps serverless-init sidecar: image <agent.serverless_init.image>:<version> and sizing."
  value = {
    image  = try("${local.si.image}:${local.si.version}", null)
    cpu    = try(local.si.cpu, 0.25)
    memory = try(local.si.memory, "0.5Gi")
  }
}

output "apm" {
  description = "Effective APM decision: requested/effective mode, method (ssi_kubernetes | ssi_host | agent_sidecar | serverless_init | agent_gateway | otlp_agent | otlp_gateway | none), fallback reason, library versions, sample rate."
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
  description = "Datadog library env for datadog mode (TELEMETRY_SDK=datadog, DD_TRACE_OTEL_ENABLED, integration service names off, log injection, DogStatsD target, sampling, DBM propagation, DSM). Empty otherwise."
  value       = merge(local.apm_env, local.dogstatsd_env)
}

output "agent_apm_ignore_resources" {
  description = "Trace-agent resources to drop (DD_APM_IGNORE_RESOURCES / apm_config.ignore_resources) for every Agent of the fleet."
  value       = try(tolist(local.policy.apm.ignore_resources), [])
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

output "sections" {
  description = "Merged policy sections (defaults -> architecture -> environment -> overrides) before the support matrix: logs, apm, profiling, agent, rum, op_worker."
  value       = local.section
}
