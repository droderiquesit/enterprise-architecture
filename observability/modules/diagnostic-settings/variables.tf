variable "resources" {
  description = <<-EOT
    Existing resources to export logs from, keyed by a STABLE caller-chosen key (renaming a key recreates
    its settings). app_log_route says who collects the resource's APPLICATION logs:
      eventhub  -> app-log categories are exported to the app-logs hub (Fluent Bit aggregator ships them)
      sidecar | daemonset | host | none -> app-log categories are NOT exported (no duplicates)
    Platform (non-application) categories from the allow-list go to the platform-logs hub when platform_logs = true.
  EOT
  type = map(object({
    id            = string
    app_log_route = optional(string, "none")
    platform_logs = optional(bool, true)
    location      = optional(string)
    # replaces the allow-list for this resource (still intersected with what the resource supports)
    platform_categories = optional(list(string))
  }))
  validation {
    condition     = alltrue([for r in values(var.resources) : contains(["eventhub", "sidecar", "daemonset", "host", "none"], r.app_log_route)])
    error_message = "app_log_route must be one of eventhub, sidecar, daemonset, host, none."
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

variable "platform_log_allowlist" {
  description = "Platform (non-application) log categories per resource type (lower-case type). Intersected with the categories the resource actually supports."
  type        = map(list(string))
  default = {
    "microsoft.web/sites"                            = ["AppServiceHTTPLogs", "AppServicePlatformLogs", "AppServiceAuditLogs", "AppServiceIPSecAuditLogs", "AppServiceAuthenticationLogs"]
    "microsoft.web/sites/slots"                      = ["AppServiceHTTPLogs", "AppServicePlatformLogs"]
    "microsoft.app/managedenvironments"              = ["ContainerAppSystemLogs"]
    "microsoft.logic/workflows"                      = []
    "microsoft.containerservice/managedclusters"     = ["kube-audit-admin", "cluster-autoscaler", "guard"]
    "microsoft.sql/servers/databases"                = ["SQLSecurityAuditEvents", "Errors", "Timeouts", "Blocks", "Deadlocks", "AutomaticTuning"]
    "microsoft.sql/managedinstances"                 = ["SQLSecurityAuditEvents", "ResourceUsageStats"]
    "microsoft.dbforpostgresql/flexibleservers"      = ["PostgreSQLLogs", "PostgreSQLFlexSessions"]
    "microsoft.dbformysql/flexibleservers"           = ["MySqlSlowLogs", "MySqlAuditLogs"]
    "microsoft.documentdb/databaseaccounts"          = ["ControlPlaneRequests"]
    "microsoft.keyvault/vaults"                      = ["AuditEvent"]
    "microsoft.servicebus/namespaces"                = ["OperationalLogs", "RuntimeAuditLogs"]
    "microsoft.eventhub/namespaces"                  = ["OperationalLogs"]
    "microsoft.network/applicationgateways"          = ["ApplicationGatewayAccessLog", "ApplicationGatewayFirewallLog"]
    "microsoft.network/frontdoors"                   = ["FrontdoorAccessLog", "FrontdoorWebApplicationFirewallLog"]
    "microsoft.cdn/profiles"                         = ["FrontDoorAccessLog", "FrontDoorWebApplicationFirewallLog"]
    "microsoft.apimanagement/service"                = ["GatewayLogs"]
    "microsoft.cache/redis"                          = ["ConnectedClientList"]
    "microsoft.containerregistry/registries"         = ["ContainerRegistryLoginEvents"]
    "microsoft.storage/storageaccounts/blobservices" = ["StorageWrite", "StorageDelete"]
  }
}
