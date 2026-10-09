variable "settings" {
  description = "deploy-appservice settings (environments/<env>/environment.yaml components.deploy-appservice)."
  type = object({
    faults_enabled     = optional(bool, false)
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    inventory = optional(object({
      enabled           = optional(bool, true)  # hello-inventory-api, Windows code (zip)
      container_enabled = optional(bool, false) # Windows container variant (Premium v3 Windows container plan cost)
      staging_slot      = optional(bool, true)  # swap-based releases where the SKU supports slots
    }), {})
    catalog_container_enabled = optional(bool, false) # hello-catalog-api Linux container variant
    redis_cache_ttl_seconds   = optional(number, 60)
    # Private by default: private endpoint when foundation_network is present, else public with Deny default.
    network_mode      = optional(string, "auto")
    allowed_ip_ranges = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = contains(["auto", "private-endpoint", "restricted"], var.settings.network_mode)
    error_message = "network_mode must be auto, private-endpoint or restricted."
  }
}
