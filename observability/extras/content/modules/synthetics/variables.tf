variable "tests" {
  description = "Synthetic tests keyed by a stable id (\"<service>/<endpoint>[/browser]\"). URLs must already be resolved."
  type = map(object({
    kind             = string # api | browser
    name             = string
    url              = string
    health_path      = optional(string, "/healthz")
    locations        = optional(list(string), [])
    private_location = optional(bool, false)
    tick_every       = optional(number, 300)
    tags             = optional(list(string), [])
    message          = string
    handles          = list(string)
    browser_steps = optional(list(object({
      name  = string
      type  = string
      value = optional(string)
    })), [])
  }))

  validation {
    condition     = alltrue([for t in values(var.tests) : contains(["api", "browser"], t.kind)])
    error_message = "kind must be api or browser."
  }
  validation {
    condition     = alltrue([for t in values(var.tests) : can(regex("^https?://", t.url))])
    error_message = "Every test URL must be an absolute http(s) URL (resolve references before calling this module)."
  }
}

variable "private_location_id" {
  description = "Datadog private location id (\"pl:...\") used for tests flagged private_location. Null skips private tests."
  type        = string
  default     = null
}

variable "paused" {
  description = "Create tests paused (default for non-production)."
  type        = bool
  default     = true
}

variable "response_time_ms" {
  description = "API test response-time assertion (ms)."
  type        = number
  default     = 5000
}

variable "min_failure_duration" {
  description = "Seconds a test must fail before it alerts (options.min_failure_duration)."
  type        = number
  default     = 120
}

variable "min_location_failed" {
  description = "Number of failing locations that triggers an alert (options.min_location_failed)."
  type        = number
  default     = 1
}

variable "retry" {
  description = "Retries of a failed test run: count and interval in milliseconds (options.retry)."
  type        = object({ count = number, interval = number })
  default     = { count = 1, interval = 300 }
}

variable "browser_device_ids" {
  description = "Browser test devices."
  type        = list(string)
  default     = ["chrome.laptop_large"]
}
