variable "settings" {
  description = "deploy-dbadapters settings (environments/<env>/environment.yaml components.deploy-dbadapters)."
  type = object({
    faults_enabled     = optional(bool, false)
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    replica_ceiling    = optional(number, 3)
    # Per-family overrides. hosting: aca | aca-dedicated | appservice | vmss (default from catalog/architecture-matrix.yaml).
    families = optional(map(object({
      enabled      = optional(bool, true)
      hosting      = optional(string)
      min_replicas = optional(number, 0)
      max_replicas = optional(number, 2)
    })), {})
    region_display_name = optional(string)      # Cosmos Cassandra local DC (e.g. "Sweden Central"); default derived from location
    vmss_package_force  = optional(string, "1") # bump to force the VMSS CustomScript to re-run (model update)
    network_mode        = optional(string, "auto")
    allowed_ip_ranges   = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = alltrue([for f in values(var.settings.families) : f.hosting == null || contains(["aca", "aca-dedicated", "appservice", "vmss"], coalesce(f.hosting, "aca"))])
    error_message = "families.<f>.hosting must be aca, aca-dedicated, appservice or vmss."
  }
  validation {
    condition     = alltrue([for f in values(var.settings.families) : f.min_replicas <= f.max_replicas && f.max_replicas <= var.settings.replica_ceiling])
    error_message = "families: min_replicas <= max_replicas <= replica_ceiling."
  }
}
