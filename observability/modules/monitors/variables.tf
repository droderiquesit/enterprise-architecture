variable "monitors" {
  description = "Fully resolved monitor specs keyed by a stable id (normally \"<service>/<monitor_key>\"). Produced by modules/onboarding from rendered service JSON; usable directly."
  type = map(object({
    name                = string
    type                = string
    query               = string
    message             = string
    priority            = optional(number, 3)
    tags                = optional(list(string), [])
    notify_no_data      = optional(bool, false)
    no_data_timeframe   = optional(number)
    require_full_window = optional(bool, false)
    evaluation_delay    = optional(number)
    new_group_delay     = optional(number)
    renotify_interval   = optional(number, 0)
    thresholds = object({
      critical          = number
      warning           = optional(number)
      critical_recovery = optional(number)
      warning_recovery  = optional(number)
    })
    notify = object({
      alert   = list(string)
      warning = optional(list(string), [])
    })
  }))

  validation {
    condition     = alltrue([for m in values(var.monitors) : length(m.notify.alert) > 0])
    error_message = "Every monitor needs at least one alert route key."
  }
  validation {
    condition     = alltrue([for m in values(var.monitors) : strcontains(m.message, "Runbook: http")])
    error_message = "Every monitor message must contain a runbook link (\"Runbook: https://...\")."
  }
}

variable "route_handles" {
  description = "Route key -> @-handles, from modules/notification-routing (output route_handles)."
  type        = map(list(string))
}

variable "extra_tags" {
  description = "Tags added to every monitor (e.g. [\"source:observability-package\"])."
  type        = list(string)
  default     = []
}
