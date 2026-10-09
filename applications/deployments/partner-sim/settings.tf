variable "settings" {
  description = "deploy-partner-sim settings (environments/<env>/environment.yaml components.deploy-partner-sim)."
  type = object({
    faults_enabled       = optional(bool, false)
    log_level            = optional(string, "info")
    trace_sample_ratio   = optional(number, 1)
    cpu                  = optional(number, 0.5)
    memory_gb            = optional(number, 1)
    latency_ms_mean      = optional(number, 120)
    partner_failure_rate = optional(number, 0) # lab only; > 0 makes /payments decline/fail randomly
    dns_record_name      = optional(string, "partner-sim")
  })
  default = {}

  validation {
    condition     = var.settings.partner_failure_rate >= 0 && var.settings.partner_failure_rate <= 1 && var.settings.cpu <= 2 && var.settings.memory_gb <= 4
    error_message = "partner_failure_rate 0..1; cpu <= 2 and memory_gb <= 4 (lab ceiling)."
  }
}
