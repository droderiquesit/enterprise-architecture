locals {
  mode = coalesce(var.settings.mode, var.settings.app_client_id != null ? "app_registration" : "none")
  # the client secret is read only for secret-based app registration auth (sensitive; lands in state as
  # the integration's client_secret - documented exception; use app_auth = secretless to avoid it)
  read_secret     = local.mode == "app_registration" && var.settings.app_auth == "secret"
  default_filters = [{ name = "application", value = "enterprise-hello", action = "Include" }]
}

data "azurerm_key_vault_secret" "client_secret" {
  count        = local.read_secret ? 1 : 0
  name         = var.settings.client_secret_name
  key_vault_id = var.foundation_identity.key_vault_id
}

module "integration" {
  source             = "../../modules/azure-integration"
  mode               = local.mode
  tenant_id          = var.environment.tenant_id
  subscription_ids   = concat([var.environment.subscription_id], var.settings.extra_subscription_ids)
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
  client_secret = local.read_secret ? data.azurerm_key_vault_secret.client_secret[0].value : null
  native        = local.mode == "native" ? { existing_monitor_id = var.settings.native_monitor_id } : null
}
