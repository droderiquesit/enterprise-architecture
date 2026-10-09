variable "slos" {
  description = "SLO specs keyed by \"<service>/<slo name>\" (rendered by tools/onboarding/render.py)."
  type = map(object({
    display_name = string
    description  = optional(string, "")
    type         = string # availability | latency
    target       = number
    warning      = optional(number)
    timeframe    = string
    tags         = optional(list(string), [])
    numerator    = optional(string)
    denominator  = optional(string)
    time_slice = optional(object({
      query      = string
      comparator = string
      threshold  = number
    }))
    burn_rate_alerts = optional(list(object({
      severity     = string
      name         = string
      message      = string
      long_window  = string
      short_window = string
      threshold    = number
      notify       = object({ alert = list(string) })
    })), [])
  }))

  validation {
    condition = alltrue([for s in values(var.slos) : (
      s.type == "availability" ? (s.numerator != null && s.denominator != null) : s.time_slice != null
    )])
    error_message = "availability SLOs need numerator/denominator; latency SLOs need time_slice."
  }
  validation {
    condition     = alltrue([for s in values(var.slos) : contains(["7d", "30d", "90d"], s.timeframe)])
    error_message = "timeframe must be 7d, 30d or 90d."
  }
  validation {
    condition = alltrue(flatten([for s in values(var.slos) : [
      for b in s.burn_rate_alerts : b.threshold > 0 && b.threshold <= 1 / (1 - s.target / 100)
    ]]))
    error_message = "Burn rate thresholds must satisfy 0 < threshold <= 1/(1 - target) (Datadog limit)."
  }
}

variable "route_handles" {
  description = "Route key -> @-handles."
  type        = map(list(string))
}
