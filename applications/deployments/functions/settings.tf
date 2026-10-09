variable "settings" {
  description = "deploy-functions settings (environments/<env>/environment.yaml components.deploy-functions)."
  type = object({
    faults_enabled     = optional(bool, false)
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    python_version     = optional(string, "3.13")
    # Python v2 programming model function names in applications/services/functions (audit, cache-warmer, quote).
    function_names = optional(object({
      audit        = optional(string, "audit")
      cache_warmer = optional(string, "cache_warmer")
      quote        = optional(string, "quote")
    }), {})
    premium_enabled        = optional(bool, true) # audit on Elastic Premium (EP1, Linux)
    dedicated_enabled      = optional(bool, true) # cache-warmer on the platform-appservice Linux plan
    container_apps_enabled = optional(bool, true) # quote on Functions on Container Apps (kind=functionapp, azapi)
    premium_max_scale_out  = optional(number, 3)
    aca_max_replicas       = optional(number, 3)
    cache_warm_schedule    = optional(string, "0 */15 * * * *")
    catalog_api_url        = optional(string) # cache-warmer target (deploy-core-* hello-catalog-api URL)
    # Private by default: private endpoint when foundation_network is present, else public with Deny default.
    network_mode      = optional(string, "auto")
    allowed_ip_ranges = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = contains(["auto", "private-endpoint", "restricted"], var.settings.network_mode) && var.settings.premium_max_scale_out <= 20 && var.settings.aca_max_replicas <= 10
    error_message = "network_mode auto|private-endpoint|restricted; premium_max_scale_out <= 20; aca_max_replicas <= 10 (lab ceilings)."
  }
}
