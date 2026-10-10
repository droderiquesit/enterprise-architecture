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
  description = "Fluent Bit sidecar secrets: env-yaml NAME -> dsv:// reference written by dsv-fetch (empty without a sidecar)."
  value       = local.uses_sidecar ? local.sidecar_secret_refs : {}
}

output "fetch_args" {
  description = "dsv-fetch command line used for the sidecar secrets (init --format env-yaml ...)."
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
  description = "Config-file secrets, volumes (incl. EmptyDir dsv-secrets), dsv-fetch init_containers, app container env/mounts and the Fluent Bit sidecar, shaped like azurerm_container_app template blocks."
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
  description = "Fluent Bit sidecar + dsv-fetch refresher container + volumes for azurerm_container_group (no secret values: dsv-fetch writes the env file at run time)."
  value       = local.aci_sidecar
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
  description = "Effective APM decision from the fleet policy: mode (datadog | otel | none), method (ssi_kubernetes | ssi_host | agent_gateway | serverless_init | otlp_agent | otlp_gateway | none), fallback reason, library versions; ready = false when agent_gateway lacks the contract's env.apm_gateway.DD_TRACE_AGENT_URL."
  value       = merge(local.apm, { ready = local.gateway_ready })
}

output "profiling" {
  description = "Effective Continuous Profiler decision {requested, enabled, supported, preview, reason, env}."
  value       = local.profiling
}

output "log_collector" {
  description = "Application-log collector of this workload: datadog-agent | fluent-bit | fluent-bit-sidecar | diagnostic-settings."
  value       = local.log_collector
}

output "log_pipeline" {
  description = "observability_pipelines | fluent_bit_direct (fleet policy)."
  value       = module.fleet.log_pipeline
}

output "app_requirements" {
  description = "What the application image / package must contain for the chosen path (hand to the application owner)."
  value = compact([
    local.dd_mode && var.runtime == "python" && !contains(["ssi_kubernetes", "ssi_host"], coalesce(local.apm.method, "none")) ? "Python: ddtrace in the image/package; the app starts it when TELEMETRY_SDK=datadog (import ddtrace.auto / ddtrace-run); OTel SDK init skipped" : "",
    local.dd_mode && var.runtime == "dotnet" && contains(["agent_gateway", "serverless_init"], coalesce(local.apm.method, "none")) ? (contains(["appservice", "functions"], var.architecture) ? "dotnet: Datadog.Trace.Bundle NuGet package in the app (tracer + profiler under ${local.tracer_home})" : "dotnet: dd-trace-dotnet installed at ${local.tracer_home} in the image (tracer + continuous profiler)") : "",
    local.dd_mode && contains(["ssi_kubernetes", "ssi_host"], coalesce(local.apm.method, "none")) ? "Single Step Instrumentation injects the Datadog library; the app must not initialise the OTel SDK when TELEMETRY_SDK=datadog" : "",
    local.apm.method == "serverless_init" ? "Container Apps: the app identity reads the Datadog API key (${var.telemetry.api_key_ref}) from Delinea DSV (dsv-fetch writes it for the serverless-init sidecar; no Container Apps secret)" : "",
    local.otel_mode && var.runtime != "browser" ? "OpenTelemetry SDK (TELEMETRY_SDK=otel)" : "",
  ])
}
