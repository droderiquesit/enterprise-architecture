output "log_route" {
  description = "Authoritative application-log route for this architecture: daemonset | host | sidecar | eventhub."
  value       = local.log_route
}

output "otlp_target" {
  description = "agent (node/host Datadog Agent OTLP receiver) or gateway (OTel gateway in the observability subnet)."
  value       = local.otlp_target
}

output "env" {
  description = "Environment for the application container/process: telemetry env + DSV runtime env (DSV_TENANT/DSV_TLD/DSV_BASE_URL/DSV_AUTH/AZURE_CLIENT_ID) + secret settings whose VALUE is a dsv:// reference (resolved by the app at start-up). No secret values."
  value       = local.env
}

output "secret_env" {
  description = "Subset of env whose value is a Delinea DSV reference (name -> dsv://...). Already included in env."
  value       = local.secret_env
}

output "dsv_env" {
  description = "DSV runtime env contract for workloads and dsv-fetch (no credentials)."
  value       = local.dsv_env
}

output "sidecar_secret_refs" {
  description = "Fluent Bit sidecar secrets (fallback, log_pipeline = fluent_bit_direct): env-yaml NAME -> dsv:// reference written by dsv-fetch (empty without a Fluent Bit sidecar)."
  value       = local.uses_sidecar ? local.sidecar_secret_refs : {}
}

output "fetch_args" {
  description = "dsv-fetch command line used for the Fluent Bit sidecar secrets (init --format env-yaml ...; fallback only)."
  value       = local.fetch_args
}

output "k8s_patch" {
  description = "Strategic-merge patch (YAML) for the app Deployment: unified service tags + env incl. DD_AGENT_HOST from status.hostIP."
  value       = yamlencode(local.k8s_patch_object)
}

output "k8s_patch_object" {
  description = "Same patch as an object, for kubernetes_* resources."
  value       = local.k8s_patch_object
}

output "container_app_patch" {
  description = "Shaped like azurerm_container_app template blocks: volumes (EmptyDir app-logs / dsv-bin; fallback: Secret flb-files, EmptyDir dsv-secrets), init_containers (dsv-fetch-install: binary installer, needs_identity = false; fallback dsv-fetch env-yaml fetch, needs_identity = true), refresher_containers (fallback on Dedicated profiles), app container env/mounts, sidecars (serverless-init `datadog` by default; `fluent-bit` only with fluent_bit_direct) and the non-secret Fluent Bit config-file secrets."
  value       = local.container_app_patch
}

output "container_app_patch_json" {
  description = "container_app_patch encoded as JSON (for non-Terraform pipelines)."
  value       = jsonencode(local.container_app_patch)
}

output "app_settings" {
  description = "App Service / Functions / Logic Apps Standard app settings: plain values; secret settings carry dsv:// references the app resolves (no @Microsoft.KeyVault references)."
  value       = local.app_settings
}

output "aci_sidecar" {
  description = "azurerm_container_group additions (null when nothing is added): init_containers (dsv-fetch-install), containers (datadog-agent sidecar by default; fluent-bit + dsv-fetch refresher with fluent_bit_direct) with volumes / liveness_exec, app_volume_mounts for the app container, log_collector. No secret values: the Agent resolves ENC[dsv://...] at run time."
  value       = local.aci_sidecar
}

output "aci_agent_files" {
  description = "Files of the ACI Agent sidecar's agent-config volume (datadog.yaml, app-logs.yaml, dsv.json) and its start command - non-secret (references only); for local tests and non-Terraform pipelines."
  value = local.uses_agent_sidecar ? {
    "datadog.yaml"  = local.agent_datadog_yaml
    "app-logs.yaml" = local.agent_logs_conf
    "dsv.json"      = local.agent_dsv_json
    start           = local.agent_start
    env             = local.agent_env
  } : null
}

output "datadog_tags" {
  description = "Comma separated k:v list of every policy tag (Fluent Bit ddtags format)."
  value       = local.dd_tags
}

output "tags" {
  description = "Rendered Datadog tag set of this workload (modules/tagging: key -> normalised value)."
  value       = module.tags.tags
}

output "unified_tags" {
  description = "{env, service, version} after the tag policy (value_map + Datadog normalisation)."
  value       = module.tags.unified
}

output "otel_resource_attributes" {
  description = "OTEL_RESOURCE_ATTRIBUTES as a map (policy attributes + cloud.provider/cloud.platform + extra_resource_attributes)."
  value       = local.resource_attributes
}

output "k8s_labels" {
  description = "Pod/workload labels (tags.datadoghq.com/* + label-safe policy tags + logs.datadoghq.com/source)."
  value       = local.k8s_labels
}

output "k8s_annotations" {
  description = "Pod annotations (ad.datadoghq.com/tags = every non-unified policy tag)."
  value       = local.k8s_annotations
}

output "azure_tags" {
  description = "Azure resource tags for the workload's app resource (the Datadog Azure integration imports them onto its metrics)."
  value       = module.tags.azure_tags
}

output "rum_global_context" {
  description = "Browser RUM: global context properties (non-unified policy tags); env/service/version go to datadogRum.init."
  value       = module.tags.rum_global_context
}

output "apm" {
  description = "Effective APM decision from the fleet policy: mode (datadog | otel | none), method (ssi_kubernetes | ssi_host | agent_sidecar | serverless_init | agent_gateway | otlp_agent | otlp_gateway | none), fallback reason, library versions; ready = false when agent_gateway lacks the contract's env.apm_gateway.DD_TRACE_AGENT_URL."
  value       = merge(local.apm, { ready = local.gateway_ready })
}

output "profiling" {
  description = "Effective Continuous Profiler decision {requested, enabled, supported, preview, reason, env}."
  value       = local.profiling
}

output "log_collector" {
  description = "Application-log collector of this workload: datadog-agent | datadog-agent-sidecar (ACI) | serverless-init (Container Apps) | diagnostic-settings | fluent-bit | fluent-bit-sidecar (fluent_bit_direct) | none."
  value       = local.log_collector
}

output "log_collector_reason" {
  description = "Why the collector differs from the requested logs.collector (fleet policy), null otherwise."
  value       = module.fleet.log_collector_reason
}

output "log_pipeline" {
  description = "observability_pipelines | fluent_bit_direct (fleet policy)."
  value       = module.fleet.log_pipeline
}

output "app_requirements" {
  description = "What the application image / package must contain for the chosen path (hand to the application owner)."
  value = compact([
    local.dd_mode && var.runtime == "python" && !contains(["ssi_kubernetes", "ssi_host"], coalesce(local.apm.method, "none")) ? "Python: ddtrace in the image/package; the app starts it when TELEMETRY_SDK=datadog (import ddtrace.auto / ddtrace-run); OTel SDK init skipped" : "",
    local.dd_mode && var.runtime == "dotnet" && contains(["agent_gateway", "serverless_init", "agent_sidecar"], coalesce(local.apm.method, "none")) ? (contains(["appservice", "functions"], var.architecture) ? "dotnet: Datadog.Trace.Bundle NuGet package in the app (tracer + profiler under ${local.tracer_home})" : "dotnet: dd-trace-dotnet installed at ${local.tracer_home} in the image (tracer + continuous profiler)") : "",
    local.dd_mode && contains(["ssi_kubernetes", "ssi_host"], coalesce(local.apm.method, "none")) ? "Single Step Instrumentation injects the Datadog library; the app must not initialise the OTel SDK when TELEMETRY_SDK=datadog" : "",
    local.uses_serverless_init ? "Container Apps: the app identity must read the Datadog API key (${var.telemetry.api_key_ref}) from Delinea DSV (the serverless-init sidecar resolves it with the dsv-fetch binary; no Container Apps secret)" : "",
    local.uses_agent_sidecar ? "ACI: the container group identity must read the Datadog API key (${var.telemetry.api_key_ref}) from Delinea DSV (the Agent sidecar's dsv-fetch secret backend)" : "",
    local.file_tail && var.runtime != "browser" && contains(["aca", "aci"], var.architecture) ? "The app writes JSON log lines to LOG_FILE_PATH (${var.log_file_path}, shared volume) - the ${local.log_collector} sidecar tails it" : "",
    local.otel_mode && var.runtime != "browser" ? "OpenTelemetry SDK (TELEMETRY_SDK=otel)" : "",
  ])
}
