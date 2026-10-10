variable "environment" {
  description = "Environment globals (ADR-0001 section 6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "settings" {
  description = "obs-prereqs settings (environments/<env>/environment.yaml components.obs-prereqs)."
  type = object({
    datadog_site = optional(string, "datadoghq.com")
    rum_applications = optional(map(object({
      # create: datadog_rum_application here (default) | existing: application_id + client_token of an existing app
      mode                       = optional(string, "create")
      application_id             = optional(string)
      client_token               = optional(string)
      service                    = optional(string)
      type                       = optional(string, "browser")
      session_sample_rate        = optional(number, 100)
      session_replay_sample_rate = optional(number, 0)
      default_privacy_level      = optional(string, "mask-user-input")
      track_user_interactions    = optional(bool, true)
    })), { "hello-frontend" = {} })
  })
  default = {}

  validation {
    condition     = alltrue([for a in values(var.settings.rum_applications) : a.session_sample_rate >= 0 && a.session_sample_rate <= 100 && a.session_replay_sample_rate >= 0 && a.session_replay_sample_rate <= 100])
    error_message = "Sample rates are percentages (0-100)."
  }
}
