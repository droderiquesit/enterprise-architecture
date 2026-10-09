variable "settings" {
  description = "deploy-core-aks settings (environments/<env>/environment.yaml components.deploy-core-aks)."
  type = object({
    kubelogin_mode     = optional(string, "azurecli") # azurecli | workloadidentity
    namespace          = optional(string, "hello")
    faults_enabled     = optional(bool, false)
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    replica_ceiling    = optional(number, 6)
    # internal-lb: hello-bff Service type LoadBalancer on an internal Azure LB (HTTP, VNet only).
    # app-routing: Ingress (class webapprouting.kubernetes.azure.com) with TLS from Key Vault; requires the
    #              AKS application routing add-on (platform-aks web_app_routing) - not enabled today.
    exposure = optional(object({
      mode                 = optional(string, "internal-lb")
      host                 = optional(string) # app-routing: DNS host name
      tls_cert_keyvault_id = optional(string) # app-routing: Key Vault certificate URI (versionless)
      tls_secret_name      = optional(string, "hello-bff-tls")
    }), {})
    cors_allowed_origins = optional(list(string), [])
    auth_mode            = optional(string, "none")
    inventory_api_url    = optional(string)
    adapters = optional(list(object({
      family = string
      url    = string
    })), [])
    redis_cache_ttl_seconds = optional(number, 60)
    apps = optional(map(object({
      enabled        = optional(bool, true)
      min_replicas   = optional(number, 1)
      max_replicas   = optional(number, 3)
      cpu_request    = optional(string, "100m")
      cpu_limit      = optional(string, "500m")
      memory_request = optional(string, "192Mi")
      memory_limit   = optional(string, "512Mi")
      target_cpu     = optional(number, 70)
      })), {
      "hello-bff"         = {}
      "hello-orders-api"  = {}
      "hello-catalog-api" = {}
      "hello-worker"      = {}
    })
  })
  default = {}

  validation {
    condition     = contains(["azurecli", "workloadidentity"], var.settings.kubelogin_mode)
    error_message = "kubelogin_mode must be azurecli or workloadidentity."
  }
  validation {
    condition     = contains(["internal-lb", "app-routing"], var.settings.exposure.mode) && (var.settings.exposure.mode != "app-routing" || var.settings.exposure.host != null)
    error_message = "exposure.mode must be internal-lb or app-routing (app-routing requires exposure.host)."
  }
  validation {
    condition     = alltrue([for k, a in var.settings.apps : contains(["hello-bff", "hello-orders-api", "hello-catalog-api", "hello-worker"], k) && a.min_replicas >= 1 && a.min_replicas <= a.max_replicas && a.max_replicas <= var.settings.replica_ceiling])
    error_message = "apps: known services only; 1 <= min_replicas <= max_replicas <= replica_ceiling (AKS has no scale-to-zero for Deployments here)."
  }
}
