locals {
  mode = coalesce(var.settings.mode, var.settings.app_client_id != null ? "app_registration" : "none")
  # app_auth = secretless (default) needs no secret. app_auth = secret: the pipeline fetches the client secret from
  # Delinea DSV just in time (tools/secrets/fetch.py -> TF_VAR_datadog_azure_client_secret, masked); it lands in
  # state as datadog_integration_azure.client_secret (provider has no write-only argument - documented exception).
  # No data source reads any secret here.
  use_secret       = local.mode == "app_registration" && var.settings.app_auth == "secret"
  default_filters  = [{ name = "application", value = "enterprise-hello", action = "Include" }]
  subscription_ids = concat([var.environment.subscription_id], var.settings.extra_subscription_ids)
}

module "integration" {
  source             = "../../modules/azure-integration"
  mode               = local.mode
  tenant_id          = var.environment.tenant_id
  subscription_ids   = local.subscription_ids
  metric_tag_filters = length(var.settings.metric_tag_filters) > 0 ? var.settings.metric_tag_filters : local.default_filters
  settings = {
    custom_metrics_enabled      = var.settings.custom_metrics_enabled
    resource_collection_enabled = var.settings.resource_collection_enabled
  }
  app_registration = local.mode == "app_registration" ? {
    client_id                   = var.settings.app_client_id
    auth                        = var.settings.app_auth
    service_principal_object_id = var.settings.app_service_principal_id
  } : null
  client_secret = local.use_secret ? var.datadog_azure_client_secret : null
  native = local.mode == "native" ? {
    existing_monitor_id    = var.settings.native_monitor_id
    send_subscription_logs = var.settings.native_logs.subscription_logs
    send_resource_logs     = var.settings.native_logs.resource_logs
    send_aad_logs          = var.settings.native_logs.aad_logs
    log_tag_filters        = var.settings.native_logs.tag_filters
  } : null
  eventhub_log_forwarding = {
    activity_log_subscription_ids = var.settings.eventhub_log_forwarding.activity_logs ? local.subscription_ids : []
    resource_log_subscription_ids = var.settings.eventhub_log_forwarding.resource_logs ? [var.environment.subscription_id] : []
    entra_enabled                 = var.settings.eventhub_log_forwarding.entra
  }
}

# Datadog-side handling of the Azure platform / control-plane logs: dashboard + log-based metrics by default,
# index / pipeline opt-in (org-wide objects).
module "log_management" {
  source = "../../modules/log-management"

  env = var.environment.name
  index = {
    enabled        = var.settings.log_management.index
    name           = "azure-platform-${var.environment.name}"
    retention_days = var.settings.log_management.index_retention_days
    daily_limit    = var.settings.log_management.index_daily_limit
  }
  pipeline  = { enabled = var.settings.log_management.pipeline }
  metrics   = { enabled = var.settings.log_management.metrics }
  dashboard = { enabled = var.settings.log_management.dashboard, entra = var.settings.log_management.dashboard_entra }
}
