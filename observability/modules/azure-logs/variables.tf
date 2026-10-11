variable "activity_log" {
  description = <<-EOT
    Subscription Activity Log (control plane) -> Event Hubs, one subscription-scoped diagnostic setting per
    subscription id. The Activity Log is a global (non-regional) source, so the Event Hub may be in any region of
    the same tenant. Removing a subscription (or enabled = false) deletes ONLY its diagnostic setting.
  EOT
  type = object({
    enabled          = optional(bool, true)
    subscription_ids = optional(list(string), [])
    categories       = optional(list(string), ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"])
    setting_name     = optional(string, "datadog-obs-activity-logs")
  })
  default = {}
  validation {
    condition     = alltrue([for s in var.activity_log.subscription_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", s))])
    error_message = "activity_log.subscription_ids must be subscription GUIDs (not /subscriptions/... ids)."
  }
  validation {
    condition     = length(var.activity_log.subscription_ids) == length(distinct([for s in var.activity_log.subscription_ids : lower(s)]))
    error_message = "activity_log.subscription_ids contains duplicates."
  }
  validation {
    condition     = length(var.activity_log.categories) > 0 && alltrue([for c in var.activity_log.categories : contains(["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"], c)])
    error_message = "activity_log.categories: one or more of Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth."
  }
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,64}$", var.activity_log.setting_name))
    error_message = "activity_log.setting_name: 1-64 letters, digits and dashes."
  }
}

variable "entra" {
  description = "Optional tenant-wide Entra ID logs -> Event Hubs; acknowledge_prerequisites = true confirms Security Administrator, Entra ID P1/P2 for sign-in logs and a namespace in the same tenant (README)."
  type = object({
    enabled                   = optional(bool, false)
    acknowledge_prerequisites = optional(bool, false)
    categories                = optional(list(string), ["AuditLogs", "SignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs"])
    setting_name              = optional(string, "datadog-obs-entra-logs")
    # null = same hub/rule as the activity log
    eventhub_name         = optional(string)
    authorization_rule_id = optional(string)
  })
  default = {}
  validation {
    condition     = !var.entra.enabled || var.entra.acknowledge_prerequisites
    error_message = "entra.enabled requires entra.acknowledge_prerequisites = true: Security Administrator role for the deploying identity, Entra ID P1/P2 for sign-in logs, Event Hub in the same tenant (see README)."
  }
  validation {
    condition = length(var.entra.categories) > 0 && alltrue([for c in var.entra.categories : contains([
      "AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs",
      "MicrosoftServicePrincipalSignInLogs", "ProvisioningLogs", "ADFSSignInLogs", "RiskyUsers", "UserRiskEvents",
      "RiskyServicePrincipals", "ServicePrincipalRiskEvents", "RiskyAgents", "AgentRiskEvents", "MicrosoftGraphActivityLogs",
      "EnrichedOffice365AuditLogs", "NetworkAccessTrafficLogs", "RemoteNetworkHealthLogs", "CustomSecurityAttributeAuditLogs",
    ], c)])
    error_message = "entra.categories contains an unknown Microsoft Entra diagnostic-settings log category."
  }
}

variable "destination" {
  description = "Event Hubs destination: a NAMESPACE authorization rule (Manage+Send+Listen) and the hub for control-plane logs (obs-telemetry-transport event_hub.activity_logs_hub)."
  type = object({
    authorization_rule_id = string
    eventhub_name         = string
  })
  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.EventHub/namespaces/[^/]+/authorizationRules/[^/]+$", var.destination.authorization_rule_id))
    error_message = "destination.authorization_rule_id must be an Event Hubs NAMESPACE authorization rule id."
  }
}

variable "native_log_forwarding" {
  description = <<-EOT
    What the Azure Native Datadog integration (modules/azure-integration mode = native) already forwards, so the two
    paths never ingest the same logs twice. Fails the plan when this module would export the same source.
  EOT
  type = object({
    subscription_log_subscription_ids = optional(list(string), [])
    aad_logs                          = optional(bool, false)
  })
  default = {}
}
