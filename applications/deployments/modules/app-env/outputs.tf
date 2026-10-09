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
