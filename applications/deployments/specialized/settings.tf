variable "settings" {
  description = "deploy-specialized settings (environments/<env>/environment.yaml components.deploy-specialized)."
  type = object({
    log_level = optional(string, "info")
    # ARO: hello-catalog-api manifests (rendered here, applied by scripts/deploy-aro.sh with `oc apply`).
    aro_namespace   = optional(string, "hello")
    aro_catalog_env = optional(map(string), {}) # PG_HOST, REDIS_HOST ... (specialized consumes no DB contract)
    # Service Fabric managed cluster: hello-inventory-api guest executable (scripts/deploy-sf.sh with sfctl).
    sf_app_type_version = optional(string)
    sf_inventory_env    = optional(map(string), {})
    # Confidential VM: hello-worker (run command).
    cvm_worker = optional(bool, true)
    cvm_env    = optional(map(string), {})
    # Automation: python3 health-probe runbook linked to the platform schedule.
    probe_urls = optional(list(string), [])
  })
  default = {}
}
