variable "settings" {
  description = "deploy-specialized settings (environments/<env>/environment.yaml components.deploy-specialized)."
  type = object({
    log_level = optional(string, "info")
    # ARO: hello-catalog-api Helm values for applications/charts/hello-service (rendered here, installed by
    # scripts/deploy-aro.sh with `helm upgrade --install`).
    aro_namespace   = optional(string, "hello")
    aro_replicas    = optional(number, 2)
    aro_catalog_env = optional(map(string), {}) # PG_HOST, REDIS_HOST ... NON-secret (specialized consumes no DB contract)
    # Secret env from EXISTING OpenShift Secrets (created out of band, e.g. PG_PASSWORD): name -> {secretName, key}.
    aro_secret_env = optional(map(object({
      secretName = string
      key        = string
    })), {})
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

  validation {
    condition     = alltrue([for k in keys(var.settings.aro_catalog_env) : !can(regex("(PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY)$", k))]) && var.settings.aro_replicas >= 1 && var.settings.aro_replicas <= 20
    error_message = "aro_catalog_env must not carry secrets (use aro_secret_env -> existing Secret); 1 <= aro_replicas <= 20."
  }
}
