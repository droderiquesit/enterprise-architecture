variable "resources" {
  description = "The fleet keyed by a stable key: literal id, ARM type, architecture / runtime / os_type (app resources), rendered tags of the owning service, optional app_log_route."
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
