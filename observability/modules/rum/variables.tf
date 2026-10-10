variable "applications" {
  description = <<-EOT
    RUM applications keyed by a stable key (normally the frontend service name).
      mode = create   : datadog_rum_application created here (name, type)
      mode = existing : an application the organisation already has (application_id + client_token; the client token is
                        Datadog's browser-facing credential, shipped to every visitor, so it is a plain value here)
    service / env / version / allowed_tracing_origins / tags render the browser SDK init (browser_config output).
  EOT
  type = map(object({
    mode           = optional(string, "create")
    name           = optional(string)
    type           = optional(string, "browser")
    application_id = optional(string)
    client_token   = optional(string)
    service        = optional(string)
    env            = optional(string)
    version        = optional(string)
    # first-party API origins that receive trace headers (exact origins, https://...)
    allowed_tracing_origins = optional(list(string), [])
    # canonical tag-policy identity of the frontend (team, owner, domain, ...) -> RUM global context
    identity = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for a in values(var.applications) : contains(["browser", "ios", "android", "react-native", "flutter", "roku", "electron", "unity", "kotlin-multiplatform"], a.type)])
    error_message = "Unsupported RUM application type."
  }
  validation {
    condition     = alltrue([for a in values(var.applications) : contains(["create", "existing"], a.mode)])
    error_message = "applications[*].mode must be create or existing."
  }
  validation {
    condition     = alltrue([for a in values(var.applications) : a.mode != "existing" || (a.application_id != null && a.client_token != null)])
    error_message = "mode = existing needs application_id and client_token (from the RUM application settings in Datadog)."
  }
  validation {
    condition     = alltrue([for a in values(var.applications) : a.mode != "create" || a.name != null])
    error_message = "mode = create needs a name."
  }
  validation {
    condition     = alltrue(flatten([for a in values(var.applications) : [for o in a.allowed_tracing_origins : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", o))]]))
    error_message = "allowed_tracing_origins must be exact https origins (first-party APIs only)."
  }
}

variable "datadog_site" {
  description = "Datadog site of the organisation (browser SDK site)."
  type        = string
  default     = "datadoghq.com"
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default): RUM sampling, replay, privacy and propagator settings."
  type        = any
  default     = null
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default): env/service/version normalisation and the global context."
  type        = any
  default     = null
}
