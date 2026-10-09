variable "settings" {
  description = "deploy-frontend settings (environments/<env>/environment.yaml components.deploy-frontend)."
  type = object({
    # Static Web Apps is not offered in swedencentral (ADR-0001 amendment 2026-10-09).
    swa_location = optional(string, "westeurope")
    # Free: public only. Standard: private endpoint / custom auth / SLA (private endpoint owned by a platform root).
    sku = optional(string, "Free")
    # API origin override (e.g. a custom domain / App Gateway). Default: deploy-core-aca, else deploy-core-aks.
    api_origin    = optional(string)
    prefer_api    = optional(string, "aca") # aca | aks when both contracts are present
    rum_app_key   = optional(string, "hello-frontend")
    extra_tracing = optional(list(string), []) # additional first-party API origins for allowedTracingUrls
  })
  default = {}

  validation {
    condition     = contains(["Free", "Standard"], var.settings.sku) && contains(["aca", "aks"], var.settings.prefer_api)
    error_message = "sku must be Free or Standard; prefer_api aca or aks."
  }
  validation {
    condition     = var.settings.api_origin == null || can(regex("^https?://[^/]+$", coalesce(var.settings.api_origin, "x")))
    error_message = "api_origin must be an origin (scheme://host[:port]) without a path."
  }
}
