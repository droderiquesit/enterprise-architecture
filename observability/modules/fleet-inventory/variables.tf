variable "resources" {
  description = <<-EOT
    The fleet: every Azure resource / workload to collect from, keyed by a stable key. Sources: onboarding manifests
    (rendered resources + identity, tools/onboarding render) and/or discovered contracts (lab diagnostics discovery).
      id            : Azure resource id (literal)
      type          : ARM type (Microsoft.Web/sites, Microsoft.Compute/virtualMachines, ...)
      architecture  : hosting of the workload on it (aks | aca | aci | appservice | functions | logicapp | vm | vmss | swa) - for app resources
      runtime       : dotnet | python | node | java | browser (app resources)
      os_type       : linux | windows
      tags          : rendered Datadog tag set of the owning service (modules/tagging / onboarding rendered tags)
      app_log_route : explicit override of the application-log route
  EOT
  type = map(object({
    id            = string
    type          = string
    architecture  = optional(string)
    runtime       = optional(string)
    os_type       = optional(string, "linux")
    tags          = optional(map(string), {})
    app_log_route = optional(string)
    tier          = optional(string)
  }))
  validation {
    condition     = alltrue([for r in values(var.resources) : can(regex("(?i)^/subscriptions/[^/]+(/resourceGroups/[^/]+)?(/providers/.+)?$", r.id))])
    error_message = "resources[*].id must be a literal Azure resource id (/subscriptions/...)."
  }
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default)."
  type        = any
  default     = null
}

variable "env" {
  description = "Environment name (fleet policy environments.<env>)."
  type        = string
  default     = ""
}
