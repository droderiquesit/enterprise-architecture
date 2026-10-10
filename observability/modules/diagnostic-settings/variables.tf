variable "resources" {
  description = <<-EOT
    Existing resources to export logs from, keyed by a STABLE caller-chosen key (renaming a key recreates
    its settings). app_log_route says who collects the resource's APPLICATION logs:
      eventhub  -> app-log categories are exported to the app-logs hub (the Observability Pipelines Worker, or the
                   Fluent Bit aggregator with fluent_bit_direct, ships them)
      sidecar | daemonset | host | none -> app-log categories are NOT exported (no duplicates)
    Platform (non-application) categories from the allow-list go to the platform-logs hub when platform_logs = true.
  EOT
  type = map(object({
    id            = string
    app_log_route = optional(string, "none")
    platform_logs = optional(bool, true)
    location      = optional(string)
    # replaces the tier/allow-list for this resource (still intersected with what the resource supports)
    platform_categories = optional(list(string))
    # per-resource tier (security | standard | verbose); null = var.platform_log_tier
    tier = optional(string)
  }))
  validation {
    condition     = alltrue([for r in values(var.resources) : contains(["eventhub", "sidecar", "daemonset", "host", "none"], r.app_log_route)])
    error_message = "app_log_route must be one of eventhub, sidecar, daemonset, host, none."
  }
  validation {
    condition     = alltrue([for r in values(var.resources) : r.tier == null || contains(["security", "standard", "verbose"], coalesce(r.tier, "standard"))])
    error_message = "resources[*].tier must be security, standard or verbose."
  }
  validation {
    condition     = alltrue([for r in values(var.resources) : can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[^/]+/[^/]+/[^/]+", r.id))])
    error_message = "Every resources[*].id must be a full Azure resource ID."
  }
}

variable "destination" {
  description = "Event Hubs destination (from the obs-telemetry-transport contract event_hub block)."
  type = object({
    authorization_rule_id = string
    app_logs_hub          = string
    platform_logs_hub     = string
    location              = optional(string)
  })
  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.EventHub/namespaces/[^/]+/authorizationRules/[^/]+$", var.destination.authorization_rule_id))
    error_message = "destination.authorization_rule_id must be an Event Hubs NAMESPACE authorization rule id."
  }
}

variable "setting_name_prefix" {
  description = "Deterministic diagnostic setting name prefix; settings are named <prefix>-app-logs / <prefix>-platform-logs."
  type        = string
  default     = "datadog-obs"
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,40}$", var.setting_name_prefix))
    error_message = "setting_name_prefix: 1-40 chars of letters, digits and dashes."
  }
}

variable "app_log_categories" {
  description = "Application-log categories per resource type (lower-case type). Exported only for app_log_route = eventhub."
  type        = map(list(string))
  default = {
    "microsoft.web/sites"               = ["AppServiceConsoleLogs", "AppServiceAppLogs", "FunctionAppLogs", "WorkflowRuntime"]
    "microsoft.web/sites/slots"         = ["AppServiceConsoleLogs", "AppServiceAppLogs", "FunctionAppLogs", "WorkflowRuntime"]
    "microsoft.app/managedenvironments" = ["ContainerAppConsoleLogs"]
    "microsoft.logic/workflows"         = ["WorkflowRuntime"]
  }
}

variable "platform_log_tier" {
  description = <<-EOT
    Default platform-category tier from category-policy.json (cumulative):
      security = audit / security essentials (Key Vault AuditEvent, SQL audit, AKS kube-audit-admin + guard, WAF, ...)
      standard = security + operational logs (AKS kube-apiserver, App Service HTTP logs, SQL errors/deadlocks, ...)
      verbose  = standard + high-volume data-plane / diagnostic categories (full kube-audit, StorageRead, Cosmos DataPlaneRequests, ...)
    resources[*].tier overrides it per resource.
  EOT
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["security", "standard", "verbose"], var.platform_log_tier)
    error_message = "platform_log_tier must be security, standard or verbose."
  }
}

variable "platform_log_allowlist_overrides" {
  description = "Per resource type (lower-case): replaces the tier policy list for that type (still intersected with what the resource supports)."
  type        = map(list(string))
  default     = {}
}

variable "platform_log_allowlist" {
  description = <<-EOT
    LEGACY (1.0.x): a complete per-type allow-list that replaces the tier policy for EVERY type. null (default) =
    use category-policy.json at platform_log_tier plus platform_log_allowlist_overrides.
  EOT
  type        = map(list(string))
  default     = null
}

variable "category_policy" {
  description = "Override the whole category policy (same shape as category-policy.json .types). null = the maintained file shipped with the module."
  type        = any
  default     = null
}
