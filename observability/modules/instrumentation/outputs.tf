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
  description = "Comma separated unified tags (DD_TAGS format)."
  value       = local.dd_tags
}
