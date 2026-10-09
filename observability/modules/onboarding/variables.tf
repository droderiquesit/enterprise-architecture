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
  type    = bool
  default = false
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
  type = object({
    enabled = optional(bool, true)
    system  = optional(string) # optional v3 system entity grouping all onboarded services
  })
  default = {}
}

variable "slos_enabled" {
  type    = bool
  default = true
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
