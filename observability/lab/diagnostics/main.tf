module "diagnostics" {
  source = "../../modules/diagnostic-settings"

  resources = { for k, r in local.all_targets : k => {
    id                  = r.id
    app_log_route       = r.app_log_route
    platform_logs       = r.platform_logs
    location            = r.location
    platform_categories = r.platform_categories
    tier                = r.tier
  } }
  destination = {
    authorization_rule_id = var.obs_telemetry_transport.event_hub.authorization_rule_id
    app_logs_hub          = var.obs_telemetry_transport.event_hub.app_logs_hub
    platform_logs_hub     = var.obs_telemetry_transport.event_hub.platform_logs_hub
    location              = var.obs_telemetry_transport.event_hub.location
  }
  setting_name_prefix              = var.settings.setting_name_prefix
  platform_log_tier                = var.settings.platform_log_tier
  platform_log_allowlist_overrides = var.settings.platform_log_allowlist_overrides
}

# Control-plane logs: subscription Activity Log (+ optional tenant-wide Entra ID logs) -> activity-logs hub.
module "azure_logs" {
  source = "../../modules/azure-logs"

  activity_log = {
    enabled          = var.settings.activity_log.enabled
    subscription_ids = distinct(concat([var.environment.subscription_id], var.settings.activity_log.extra_subscription_ids))
    categories       = var.settings.activity_log.categories
  }
  entra = {
    enabled                   = var.settings.entra.enabled
    acknowledge_prerequisites = var.settings.entra.acknowledge_prerequisites
    categories                = var.settings.entra.categories
  }
  destination = {
    authorization_rule_id = var.obs_telemetry_transport.event_hub.authorization_rule_id
    eventhub_name         = coalesce(var.obs_telemetry_transport.event_hub.activity_logs_hub, var.obs_telemetry_transport.event_hub.platform_logs_hub)
  }
  native_log_forwarding = {
    subscription_log_subscription_ids = var.settings.native_log_forwarding.subscription_logs ? distinct(concat([var.environment.subscription_id], var.settings.activity_log.extra_subscription_ids)) : []
    aad_logs                          = var.settings.native_log_forwarding.aad_logs
  }
}
