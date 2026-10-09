output "env" {
  description = "Non-secret environment variables (name -> value)."
  value       = local.env
}

output "secret_env" {
  description = "Secret environment variables (name -> versionless Key Vault secret id). Never values."
  value       = local.secret_env
}

output "secret_names" {
  description = "Container Apps secret name per secret env var."
  value       = local.secret_names
}

output "app_settings" {
  description = "App Service / Functions / Logic Apps Standard app settings (secrets as Key Vault references)."
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
