variable "settings" {
  description = "obs-diagnostics settings."
  type = object({
    setting_name_prefix = optional(string, "datadog-obs")
    # extra/override platform categories per resource type (lower-case type -> categories)
    platform_log_allowlist_overrides = optional(map(list(string)), {})
  })
  default = {}
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    event_hub = object({
      authorization_rule_id = string
      app_logs_hub          = string
      platform_logs_hub     = string
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
  }))
  default = {}
  validation {
    condition     = alltrue([for r in values(var.resources) : contains(["eventhub", "sidecar", "daemonset", "host", "none"], r.app_log_route)])
    error_message = "resources[*].app_log_route must be eventhub, sidecar, daemonset, host or none."
  }
}
