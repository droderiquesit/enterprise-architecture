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
  })
  default = {}
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
