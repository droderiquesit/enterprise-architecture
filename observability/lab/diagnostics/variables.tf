variable "settings" {
  description = "obs-diagnostics settings."
  type = object({
    setting_name_prefix = optional(string, "datadog-obs")
    # platform-category tier from modules/diagnostic-settings/category-policy.json: security | standard | verbose
    # (profile defaults: minimal -> security, enterprise/full -> standard; set it in component_settings)
    platform_log_tier = optional(string, "standard")
    # replace the tier list for a resource type (lower-case type -> categories)
    platform_log_allowlist_overrides = optional(map(list(string)), {})
    # server-level SQL audit: diagnostic setting on <server>/databases/master (SQLSecurityAuditEvents, DevOpsOperationsAudit).
    # Events flow only when platform-db-sql enables auditing with the Azure Monitor target (README "SQL audit").
    sql_server_audit = optional(bool, true)
    # subscription Activity Log -> activity-logs hub (environment subscription + extra_subscription_ids)
    activity_log = optional(object({
      enabled                = optional(bool, true)
      categories             = optional(list(string), ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"])
      extra_subscription_ids = optional(list(string), [])
    }), {})
    # Microsoft Entra ID logs (TENANT-wide; Security Administrator + P1/P2 for sign-ins): off by default
    entra = optional(object({
      enabled                   = optional(bool, false)
      acknowledge_prerequisites = optional(bool, false)
      categories                = optional(list(string), ["AuditLogs", "SignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs"])
    }), {})
    # mirror of obs-azure-integration native log forwarding (mode = native): keeps the two paths exclusive
    native_log_forwarding = optional(object({
      subscription_logs = optional(bool, false)
      resource_logs     = optional(bool, false)
      aad_logs          = optional(bool, false)
    }), {})
  })
  default = {}
  validation {
    condition     = contains(["security", "standard", "verbose"], var.settings.platform_log_tier)
    error_message = "settings.platform_log_tier must be security, standard or verbose."
  }
  validation {
    condition     = !var.settings.entra.enabled || var.settings.entra.acknowledge_prerequisites
    error_message = "settings.entra.enabled requires settings.entra.acknowledge_prerequisites = true (Security Administrator for the pipeline identity, Entra ID P1/P2 for sign-in logs, tenant-wide setting: enable it in ONE environment only)."
  }
  validation {
    condition     = !(var.settings.native_log_forwarding.subscription_logs && var.settings.activity_log.enabled)
    error_message = "The Azure Native integration already sends the subscription Activity Log (native_log_forwarding.subscription_logs); set settings.activity_log.enabled = false or turn native subscription logs off. Both would ingest every event twice."
  }
  validation {
    condition     = !(var.settings.native_log_forwarding.aad_logs && var.settings.entra.enabled)
    error_message = "The Azure Native integration already sends Entra ID logs (native_log_forwarding.aad_logs); enable only one path."
  }
  validation {
    condition     = !var.settings.native_log_forwarding.resource_logs
    error_message = "settings.native_log_forwarding.resource_logs = true: the Azure Native integration creates its own resource diagnostic settings; obs-diagnostics would ingest the same resource logs twice. Turn native resource logs off (obs-azure-integration) or do not deploy obs-diagnostics."
  }
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    fluentbit = optional(object({
      aca_console_allow = optional(list(string), [])
    }), {})
    event_hub = object({
      authorization_rule_id = string
      app_logs_hub          = string
      platform_logs_hub     = string
      activity_logs_hub     = optional(string)
      location              = optional(string)
    })
  })
}

variable "resources" {
  description = <<-EOT
    Resources to export diagnostics from, assembled by the PIPELINE (no state reads) from every enabled
    platform-* / deploy-* contract: tools/contracts/materialize.py emits resources.auto.tfvars.json with one
    entry per resource id found in those contracts, keyed "<contract>.<path>", with
      type          : informational (the module re-derives it from the id)
      app_log_route : eventhub for App Service / Functions / Logic Apps Standard sites, sidecar for ACA
                      environments (apps use the Fluent Bit sidecar), daemonset for AKS, host for VMs, else none
      location      : the resource region (cross-region resources are rejected - Event Hub must be local)
  EOT
  type = map(object({
    id            = string
    type          = optional(string)
    app_log_route = optional(string, "none")
    platform_logs = optional(bool, true)
    location      = optional(string)
    # replaces the tier list for this resource; tier overrides settings.platform_log_tier
    platform_categories = optional(list(string))
    tier                = optional(string)
  }))
  default = {}
  validation {
    condition     = alltrue([for r in values(var.resources) : contains(["eventhub", "sidecar", "daemonset", "host", "none"], r.app_log_route)])
    error_message = "resources[*].app_log_route must be eventhub, sidecar, daemonset, host or none."
  }
}

variable "discovered_contracts" {
  description = <<-EOT
    Map contract name -> contract data for every enabled platform-* and deploy-* component, passed by
    tools/contracts/materialize.py to components with discovers_resources: true. Resource ids are taken
    ONLY from the explicit extraction map in discovery.tf (README "Resource discovery"); no recursion.
  EOT
  type        = any
  default     = {}
}
