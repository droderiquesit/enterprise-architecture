variable "settings" {
  description = "deploy-specialized settings (environments/<env>/environment.yaml components.deploy-specialized)."
  type = object({
    log_level = optional(string, "info")
    # ARO: hello-catalog-api Helm values for applications/charts/hello-service (rendered here, installed by
    # scripts/deploy-aro.sh with `helm upgrade --install`). Namespace + service account come from the platform-aro
    # contract workload_identities (federated with the cluster's OIDC issuer); aro_namespace must match it.
    aro_namespace   = optional(string, "hello")
    aro_replicas    = optional(number, 2)
    aro_catalog_env = optional(map(string), {}) # PG_HOST, REDIS_HOST ... NON-secret (specialized consumes no DB contract)
    # Secret settings as Delinea DSV references (name -> dsv://<path>#<element>, e.g. PG_PASSWORD for PG_AUTH=password);
    # the app resolves them at start-up with its workload identity (ADR-0001 section 14). The hello-catalog-api identity
    # must be a reader of each path (foundation-identity secrets list). Never values; no Kubernetes Secret.
    aro_catalog_secret_env = optional(map(string), {})
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
    error_message = "aro_catalog_env must not carry secrets (use aro_catalog_secret_env -> dsv:// reference); 1 <= aro_replicas <= 20."
  }
  validation {
    condition     = alltrue([for v in values(var.settings.aro_catalog_secret_env) : can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", v))])
    error_message = "aro_catalog_secret_env values must be Delinea DSV references (dsv://<path>#<element>), never secret values."
  }
}
