variable "mode" {
  description = "app_registration (datadog_integration_azure + Entra app), native (Azure Native ISV Datadog resource) or none."
  type        = string
  default     = "app_registration"
  validation {
    condition     = contains(["app_registration", "native", "none"], var.mode)
    error_message = "mode must be app_registration, native or none."
  }
}

variable "tenant_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_ids" {
  description = "Subscriptions to monitor."
  type        = list(string)
  validation {
    condition     = length(var.subscription_ids) > 0 && alltrue([for s in var.subscription_ids : can(regex("^[0-9a-fA-F-]{36}$", s))])
    error_message = "subscription_ids must be a non-empty list of GUIDs."
  }
}

variable "metric_tag_filters" {
  description = "Azure resource tag filters for metric collection (Include / Exclude). Empty = all resources."
  type = list(object({
    name   = string
    value  = string
    action = optional(string, "Include")
  }))
  default = []
  validation {
    condition     = alltrue([for f in var.metric_tag_filters : contains(["Include", "Exclude"], f.action)])
    error_message = "metric_tag_filters[*].action must be Include or Exclude."
  }
}

variable "settings" {
  description = "Feature toggles shared by both modes."
  type = object({
    automute                    = optional(bool, true)
    custom_metrics_enabled      = optional(bool, false)
    resource_collection_enabled = optional(bool, true)
    cspm_enabled                = optional(bool, false)
    usage_metrics_enabled       = optional(bool, true)
    metrics_enabled_default     = optional(bool, true)
    app_service_plan_filters    = optional(string, "")
    container_app_filters       = optional(string, "")
  })
  default = {}
}

# ------------------------------------------------------------------ app_registration mode
variable "app_registration" {
  description = <<-EOT
    Existing Entra app registration (created outside azurerm, e.g. azuread or the portal).
    auth = secret     -> client_secret is required (pass it from Key Vault with an ephemeral/data read; it is
                         marked sensitive and never output).
    auth = secretless -> Datadog workload-identity federation (federated credential configured on the app).
    service_principal_object_id enables the per-subscription "Monitoring Reader" role assignments.
  EOT
  type = object({
    client_id                   = string
    auth                        = optional(string, "secret")
    service_principal_object_id = optional(string)
    assign_monitoring_reader    = optional(bool, true)
  })
  default = null
  validation {
    condition     = var.app_registration == null || contains(["secret", "secretless"], try(var.app_registration.auth, "secret"))
    error_message = "app_registration.auth must be secret or secretless."
  }
}

variable "client_secret" {
  description = "Client secret of the app registration (auth = secret). Source it from Key Vault in the caller."
  type        = string
  default     = null
  sensitive   = true
}

# ------------------------------------------------------------------ native mode
variable "native" {
  description = <<-EOT
    Azure Native ISV integration (Microsoft.Datadog/monitors).
    existing_monitor_id -> reuse a Datadog resource; otherwise a new one linked to an existing Datadog org
    (linking requires api_key/application_key, passed sensitive). Resource-log forwarding is OFF by default:
    it creates its own diagnostic settings and would duplicate the Event Hub / sidecar / DaemonSet routes.
  EOT
  type = object({
    existing_monitor_id    = optional(string)
    name                   = optional(string)
    resource_group_name    = optional(string)
    location               = optional(string)
    sku_name               = optional(string, "Linked")
    user_name              = optional(string)
    user_email             = optional(string)
    send_resource_logs     = optional(bool, false)
    send_subscription_logs = optional(bool, true)
    send_aad_logs          = optional(bool, false)
    log_tag_filters = optional(list(object({
      name   = string
      value  = string
      action = optional(string, "Include")
    })), [])
    assign_monitoring_reader = optional(bool, true)
  })
  default = null
}

variable "native_org_keys" {
  description = "Datadog API + application key used ONLY to link a new native monitor to an existing org."
  type = object({
    api_key         = string
    application_key = string
  })
  default   = null
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
