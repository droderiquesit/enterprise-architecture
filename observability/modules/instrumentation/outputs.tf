output "log_route" {
  description = "Authoritative application-log route for this architecture: daemonset | host | sidecar | eventhub."
  value       = local.log_route
}

output "otlp_target" {
  description = "agent (node/host Datadog Agent OTLP receiver) or gateway (OTel gateway in the observability subnet)."
  value       = local.otlp_target
}

output "env" {
  description = "Non-secret environment variables for the application container/process."
  value       = local.env
}

output "secret_env" {
  description = "Environment variables whose values must be read from Key Vault: name -> versionless secret id."
  value       = local.secret_env
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
  description = "Secrets, volumes, app container env/mounts and Fluent Bit sidecar shaped like azurerm_container_app template blocks."
  value       = local.container_app_patch
}

output "container_app_patch_json" {
  description = "container_app_patch encoded as JSON (for non-Terraform pipelines)."
  value       = jsonencode(local.container_app_patch)
}

output "app_settings" {
  description = "App Service / Functions / Logic Apps Standard app settings (secrets as @Microsoft.KeyVault references)."
  value       = local.app_settings
}

output "aci_sidecar" {
  description = "Fluent Bit sidecar + volumes for azurerm_container_group (secure env values must be resolved by the caller from the listed secret ids)."
  value       = local.aci_sidecar
}

output "datadog_tags" {
  description = "Comma separated unified tags (DD_TAGS format)."
  value       = local.dd_tags
}
