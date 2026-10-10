output "env" {
  description = "Environment (name -> value): telemetry + DSV runtime env + secret settings whose value is a dsv:// reference (resolved by the app at start-up). Never secret values."
  value       = local.env
}

output "secret_env" {
  description = "Subset of env holding Delinea DSV references (name -> dsv://...). Already included in env."
  value       = local.secret_env
}

output "dsv_env" {
  description = "DSV runtime env contract (DSV_TENANT/DSV_TLD/DSV_BASE_URL/DSV_AUTH/AZURE_CLIENT_ID)."
  value       = module.instrumentation.dsv_env
}

output "app_settings" {
  description = "App Service / Functions / Logic Apps Standard app settings: plain values, secret settings carry dsv:// references (no @Microsoft.KeyVault references)."
  value       = local.app_settings
}

output "log_route" {
  value = module.instrumentation.log_route
}

output "otlp_target" {
  value = module.instrumentation.otlp_target
}

output "container_app_patch" {
  description = "Fluent Bit sidecar, volumes and sidecar secrets for Container Apps (from the instrumentation hook)."
  value       = module.instrumentation.container_app_patch
}

output "aci_sidecar" {
  value = module.instrumentation.aci_sidecar
}

output "k8s_patch_object" {
  value = module.instrumentation.k8s_patch_object
}

output "datadog_tags" {
  value = module.instrumentation.datadog_tags
}

output "tags" {
  description = "Rendered Datadog tag set of the workload (tag policy)."
  value       = module.instrumentation.tags
}

output "azure_tags" {
  description = "Azure resource tags of the workload's app resource (same identity as its telemetry; the Datadog Azure integration imports them). Merge over the root's required tags."
  value       = module.instrumentation.azure_tags
}

output "k8s_labels" {
  description = "Pod labels: tags.datadoghq.com/* + label-safe policy tags + logs source (+ admission.datadoghq.com/enabled under SSI)."
  value       = module.instrumentation.k8s_labels
}

output "k8s_annotations" {
  description = "Pod annotations: ad.datadoghq.com/tags (+ ad.datadoghq.com/<container>.logs when the Datadog Agent collects the logs)."
  value       = module.instrumentation.k8s_annotations
}

output "extra_tags_map" {
  description = "Non-unified policy tags (Helm values service.tags -> ad.datadoghq.com/tags annotation)."
  value       = { for k, v in module.instrumentation.tags : k => v if !contains(["env", "service", "version"], k) }
}

output "apm" {
  description = "Effective APM decision (mode, method, fallback reason, ready)."
  value       = module.instrumentation.apm
}

output "profiling" {
  description = "Effective Continuous Profiler decision."
  value       = module.instrumentation.profiling
}

output "log_collector" {
  description = "datadog-agent | fluent-bit | fluent-bit-sidecar | diagnostic-settings."
  value       = module.instrumentation.log_collector
}

output "app_requirements" {
  description = "What the image / package must contain for the chosen telemetry path."
  value       = module.instrumentation.app_requirements
}
