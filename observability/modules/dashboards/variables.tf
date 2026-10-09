variable "services" {
  description = "Per-service dashboard inputs keyed by service name (built by modules/onboarding)."
  type = map(object({
    env                    = string
    team                   = string
    architecture           = string
    traces_enabled         = bool
    rum_enabled            = optional(bool, false)
    logs_enabled           = optional(bool, true)
    server_operation       = optional(string, "http.server.request")
    workflow_metric_prefix = optional(string)
    runbook_url            = string
    slo_ids                = optional(list(string), [])
    resources = optional(list(object({
      role  = string
      type  = string
      scope = string
    })), [])
  }))
}

variable "create_service_dashboards" {
  type    = bool
  default = true
}

variable "overview" {
  description = "Application overview dashboard (journey, databases, queues/durable, telemetry pipeline)."
  type = object({
    enabled        = optional(bool, true)
    title          = string
    env            = string
    journey        = optional(list(string), [])
    pipeline_scope = optional(string)
  })
}
