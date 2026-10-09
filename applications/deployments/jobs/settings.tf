variable "settings" {
  description = "deploy-jobs settings (environments/<env>/environment.yaml components.deploy-jobs)."
  type = object({
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    reconcile_cron     = optional(string, "15 * * * *")   # hourly reconcile-trigger
    traffic_cron       = optional(string, "*/30 * * * *") # synthetic traffic every 30 min
    traffic = optional(object({
      enabled          = optional(bool, true)
      rps              = optional(number, 0.2)
      duration_seconds = optional(number, 300) # bounded (<= 600, app-enforced too)
      browser_journeys = optional(number, 2)
    }), {})
    batch_processor = optional(object({
      enabled          = optional(bool, true)
      max_executions   = optional(number, 3)
      messages_per_job = optional(number, 50)
      polling_seconds  = optional(number, 30)
    }), {})
    durable_api_url = optional(string) # override; default https://<deploy-durable function_app.hostname>
    orders_api_url  = optional(string) # override; default deploy-core-aca/aks apps["hello-orders-api"].url
    adapters = optional(list(object({
      family = string
      url    = string
    })), [])
    result_tables_endpoint = optional(string) # Table Storage endpoint for process-batch-items results (else log)
  })
  default = {}

  validation {
    condition     = var.settings.traffic.duration_seconds >= 30 && var.settings.traffic.duration_seconds <= 600 && var.settings.traffic.rps > 0 && var.settings.traffic.rps <= 5
    error_message = "traffic.duration_seconds must be 30..600 and rps in (0, 5] (bounded synthetic load)."
  }
  validation {
    condition     = var.settings.batch_processor.max_executions >= 1 && var.settings.batch_processor.max_executions <= 10
    error_message = "batch_processor.max_executions must be 1..10 (lab ceiling)."
  }
}
