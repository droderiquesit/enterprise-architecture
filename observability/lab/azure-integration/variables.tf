variable "settings" {
  description = "obs-azure-integration settings."
  type = object({
    datadog_site = optional(string, "datadoghq.com")
    # null = app_registration when app_client_id is set, else none (nothing deployed until bootstrap created the app)
    mode                        = optional(string)
    app_client_id               = optional(string)
    app_auth                    = optional(string, "secret") # secret | secretless
    app_service_principal_id    = optional(string)
    client_secret_name          = optional(string, "datadog-azure-integration-client-secret")
    extra_subscription_ids      = optional(list(string), [])
    metric_tag_filters          = optional(list(object({ name = string, value = string, action = optional(string, "Include") })), [])
    custom_metrics_enabled      = optional(bool, false)
    resource_collection_enabled = optional(bool, true)
    native_monitor_id           = optional(string) # mode = native: existing Microsoft.Datadog/monitors id
    # mode = native: log forwarding by the Azure Native integration (tag rule log block). OFF in the lab: the
    # Event Hubs path (obs-diagnostics) is authoritative; the two are mutually exclusive per subscription.
    native_logs = optional(object({
      subscription_logs = optional(bool, false)
      resource_logs     = optional(bool, false)
      aad_logs          = optional(bool, false)
      tag_filters       = optional(list(object({ name = string, value = string, action = optional(string, "Include") })), [])
    }), {})
    # mirror of what obs-diagnostics exports through Event Hubs (its settings.activity_log / entra); the plan fails
    # when native_logs would forward the same source again
    eventhub_log_forwarding = optional(object({
      activity_logs = optional(bool, true)
      resource_logs = optional(bool, true)
      entra         = optional(bool, false)
    }), {})
    # Datadog-side log management for the Azure platform logs (modules/log-management)
    log_management = optional(object({
      dashboard            = optional(bool, true)
      dashboard_entra      = optional(bool, false)
      metrics              = optional(bool, true)
      index                = optional(bool, false) # org-wide object: enable only if this lab owns its Datadog org
      index_retention_days = optional(number, 15)
      index_daily_limit    = optional(number, 1000000)
      pipeline             = optional(bool, false)
    }), {})
  })
  default = {}
  validation {
    condition     = !(var.settings.native_logs.subscription_logs && var.settings.eventhub_log_forwarding.activity_logs) && !(var.settings.native_logs.resource_logs && var.settings.eventhub_log_forwarding.resource_logs) && !(var.settings.native_logs.aad_logs && var.settings.eventhub_log_forwarding.entra)
    error_message = "Native log forwarding (settings.native_logs) and the Event Hubs path (settings.eventhub_log_forwarding, mirror of obs-diagnostics) would ingest the same logs twice; enable one path per source."
  }
  validation {
    condition     = var.settings.mode == null || contains(["app_registration", "native", "none"], coalesce(var.settings.mode, "none"))
    error_message = "settings.mode must be app_registration, native or none."
  }
}

variable "foundation_identity" {
  description = "foundation-identity contract (fields used); optional - only needed for the client secret read."
  type = object({
    key_vault_id = string
  })
  default = null
}
