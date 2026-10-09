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
    # app-routing: Ingress (class webapprouting.kubernetes.azure.com) with TLS from an existing Secret
    #              (tls_secret_name, e.g. synced from Delinea DSV by the dsv-k8s syncer); requires the
    #              AKS application routing add-on (platform-aks settings.app_routing, enabled by default with an internal NGINX controller).
    # dsv (default): secret settings are dsv:// env values resolved by the app with workload identity;
    # synced (fallback): the chart reads the Secret <release>-dsv maintained by the Delinea dsv-k8s syncer
    secrets_mode = optional(string, "dsv")
    exposure = optional(object({
      mode            = optional(string, "internal-lb")
      host            = optional(string) # app-routing: DNS host name
      tls_secret_name = optional(string, "hello-bff-tls")
    }), {})
    cors_allowed_origins = optional(list(string), [])
    auth_mode            = optional(string, "none")
    inventory_api_url    = optional(string)
    adapters = optional(list(object({
      family = string
      url    = string
    })), [])
    redis_cache_ttl_seconds = optional(number, 60)
    # Helm releases (applications/charts/hello-service; one release per workload, release name = workload).
    helm = optional(object({
      # null = the chart in this repository (applications/charts/hello-service, always in sync with this root).
      # "oci://<acr login server>/helm" = the chart the applications pipeline published to ACR (chart_version required).
      chart_repository = optional(string)
      chart_version    = optional(string)
      timeout_seconds  = optional(number, 600)
      max_history      = optional(number, 10)
      # One-time migration from the pre-Helm version of this root (raw kubernetes_* objects): adopt the
      # existing Deployments/Services/... into the releases (helm --take-ownership). Leave false otherwise.
      take_ownership = optional(bool, false)
    }), {})
    # NetworkPolicy per workload (platform-aks uses Cilium network policy): ingress to the app port only from
    # namespace `hello`, the app routing namespace and network_policy_allow_cidrs (internal LB clients).
    network_policy_enabled     = optional(bool, false)
    network_policy_allow_cidrs = optional(list(string), [])
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
    condition     = (var.settings.helm.chart_repository == null || (startswith(coalesce(var.settings.helm.chart_repository, "x"), "oci://") && var.settings.helm.chart_version != null)) && var.settings.helm.timeout_seconds >= 60 && var.settings.helm.timeout_seconds <= 1800 && var.settings.helm.max_history >= 2
    error_message = "helm: chart_repository must be oci://... with chart_version; 60 <= timeout_seconds <= 1800; max_history >= 2 (rollback needs history)."
  }
  validation {
    condition     = contains(["dsv", "synced"], var.settings.secrets_mode)
    error_message = "secrets_mode must be dsv (app resolves dsv:// references with workload identity) or synced (Delinea dsv-k8s syncer Secret)."
  }
  validation {
    condition     = contains(["azurecli", "workloadidentity"], var.settings.kubelogin_mode)
    error_message = "kubelogin_mode must be azurecli or workloadidentity."
  }
  validation {
    condition     = contains(["internal-lb", "app-routing"], var.settings.exposure.mode) && (var.settings.exposure.mode != "app-routing" || var.settings.exposure.host != null)
    error_message = "exposure.mode must be internal-lb or app-routing (app-routing requires exposure.host)."
  }
  validation {
    condition     = alltrue([for k, a in var.settings.apps : contains(["hello-bff", "hello-orders-api", "hello-catalog-api", "hello-worker"], k) && a.min_replicas >= 1 && a.min_replicas <= a.max_replicas && a.max_replicas <= var.settings.replica_ceiling]) && var.settings.replica_ceiling <= 20
    error_message = "apps: known services only; 1 <= min_replicas <= max_replicas <= replica_ceiling <= 20 (chart schema ceiling; AKS has no scale-to-zero for Deployments here)."
  }
}
