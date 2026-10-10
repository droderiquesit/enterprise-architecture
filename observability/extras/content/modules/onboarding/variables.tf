variable "services" {
  description = <<-EOT
    Rendered service documents (schema rendered-service/v1) produced by tools/onboarding/render.py, e.g.
    [for f in fileset(path, "*.json") : jsondecode(file("$${path}/$${f}"))]. Typed `any` because documents
    differ in shape (monitor keys, resources).
  EOT
  type        = any

  validation {
    condition     = alltrue([for s in var.services : try(s.schema, "") == "rendered-service/v1"])
    error_message = "Every service document must be produced by render.py (schema = rendered-service/v1)."
  }
}

variable "contract_references" {
  description = "Flat map '<contract>.<dot.path>' -> value used to resolve $${contract:...} references and presence_ref (render.py references). Empty for consumers that put literal resource ids in manifests."
  type        = map(string)
  default     = {}
}

variable "routing" {
  description = "Decoded NotificationRouting document for this environment."
  type        = any
}

variable "create_webhooks" {
  description = "Create the notification webhooks of the routing file (false = they already exist in the organisation)."
  type        = bool
  default     = false
}

variable "synthetics" {
  description = "Synthetic tests: enabled, paused (true for non-prod), private_location_id for private endpoints."
  type = object({
    enabled             = optional(bool, true)
    paused              = optional(bool, true)
    private_location_id = optional(string)
    response_time_ms    = optional(number, 5000)
  })
  default = {}
}

variable "dashboards" {
  description = "Dashboards to create: per-service dashboards, the overview (title, journey services, pipeline scope)."
  type = object({
    service_dashboards = optional(bool, true)
    overview           = optional(bool, true)
    overview_title     = optional(string)
    journey            = optional(list(string), [])
    pipeline_scope     = optional(string)
  })
  default = {}
}

variable "service_catalog" {
  description = "Software Catalog entities of the onboarded services and an optional system entity grouping them."
  type = object({
    enabled = optional(bool, true)
    system  = optional(string) # optional v3 system entity grouping all onboarded services
  })
  default = {}
}

variable "slos_enabled" {
  description = "Create the SLOs (and their burn-rate monitors) of the rendered services."
  type        = bool
  default     = true
}

variable "extra_tags" {
  description = "Tags added to every monitor."
  type        = list(string)
  default     = []
}

variable "strict_references" {
  description = "Fail the plan when a required resource/endpoint reference cannot be resolved (recommended)."
  type        = bool
  default     = true
}
