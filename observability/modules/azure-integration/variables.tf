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
    auth = secretless -> (default) Datadog workload-identity federation (federated credential on the app): no secret.
    auth = secret     -> client_secret is required: the pipeline reads it from Delinea DSV just in time
                         (tools/secrets/fetch.py -> TF_VAR_*, masked) - never stored in tfvars or the repo. The
                         provider has no write-only argument, so it is persisted (encrypted) in state.
    service_principal_object_id enables the per-subscription "Monitoring Reader" role assignments.
  EOT
  type = object({
    client_id                   = string
    auth                        = optional(string, "secretless")
    service_principal_object_id = optional(string)
    assign_monitoring_reader    = optional(bool, true)
  })
  default = null
  validation {
    condition     = var.app_registration == null || contains(["secret", "secretless"], try(var.app_registration.auth, "secretless"))
    error_message = "app_registration.auth must be secret or secretless."
  }
}

variable "client_secret" {
  description = "Client secret of the app registration (auth = secret only). Supplied by the pipeline from Delinea DSV at run time (TF_VAR_*); lands in state as datadog_integration_azure.client_secret (no write-only form)."
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

variable "eventhub_log_forwarding" {
  description = <<-EOT
    What the Event Hubs path (modules/azure-logs + modules/diagnostic-settings, Fluent Bit aggregator) already
    exports - normally modules/azure-logs output log_forwarding plus the subscriptions that carry resource
    diagnostic settings. In mode = native the plan FAILS when the native tag rule would forward the same source
    for the same subscription (Activity Log, resource logs) or tenant (Entra ID): duplicates double the bill and
    every log-based alert. Native and Event Hubs log forwarding are mutually exclusive per subscription.
  EOT
  type = object({
    activity_log_subscription_ids = optional(list(string), [])
    resource_log_subscription_ids = optional(list(string), [])
    entra_enabled                 = optional(bool, false)
  })
  default = {}
  validation {
    condition = var.mode != "native" || var.native == null || !(
      try(var.native.send_subscription_logs, true) &&
      length(setintersection(toset([for s in var.subscription_ids : lower(s)]), toset([for s in var.eventhub_log_forwarding.activity_log_subscription_ids : lower(s)]))) > 0
    )
    error_message = "native.send_subscription_logs is on for a subscription whose Activity Log already goes through Event Hubs (eventhub_log_forwarding.activity_log_subscription_ids). Disable one path."
  }
  validation {
    condition = var.mode != "native" || var.native == null || !(
      try(var.native.send_resource_logs, false) &&
      length(setintersection(toset([for s in var.subscription_ids : lower(s)]), toset([for s in var.eventhub_log_forwarding.resource_log_subscription_ids : lower(s)]))) > 0
    )
    error_message = "native.send_resource_logs is on for a subscription whose resource logs already go through Event Hubs diagnostic settings. Disable one path."
  }
  validation {
    condition     = var.mode != "native" || var.native == null || !(try(var.native.send_aad_logs, false) && var.eventhub_log_forwarding.entra_enabled)
    error_message = "native.send_aad_logs and the Event Hubs Entra ID export are both on. Disable one path."
  }
}
