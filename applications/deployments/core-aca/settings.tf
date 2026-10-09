variable "settings" {
  description = "deploy-core-aca settings (environments/<env>/environment.yaml components.deploy-core-aca)."
  type = object({
    faults_enabled     = optional(bool, false) # FAULTS_ENABLED; lab environments may enable
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    replica_ceiling    = optional(number, 5) # hard upper bound for every app's max_replicas
    # Browser origins allowed to call the BFF (ingress CORS + CORS_ALLOWED_ORIGINS). The SWA hostname is only
    # known after deploy-frontend: set it here (or a custom domain) and re-apply (see README "two-pass CORS").
    cors_allowed_origins = optional(list(string), [])
    auth_mode            = optional(string, "none") # BFF AUTH_MODE: none | entra
    entra_audience       = optional(string)
    inventory_api_url    = optional(string) # e.g. deploy-appservice hello-inventory-api URL (deploy-appservice is not consumed by core-aca: it runs in parallel)
    adapters = optional(list(object({       # ADAPTERS_JSON for /api/adapters (deploy-dbadapters URLs)
      family = string
      url    = string
    })), [])
    revision_mode = optional(string, "Multiple")
    # Rollback / canary per app: latest_weight < 100 sends the remainder to previous_revision_suffix
    # (contract apps.<svc>.revision_suffix of an earlier apply).
    traffic = optional(map(object({
      latest_weight            = optional(number, 100)
      previous_revision_suffix = optional(string)
    })), {})
    apps = optional(map(object({
      enabled          = optional(bool, true)
      min_replicas     = optional(number, 0) # 0 = scale to zero (lab default)
      max_replicas     = optional(number, 3)
      cpu              = optional(number, 0.5)
      memory           = optional(string, "1Gi")
      http_concurrency = optional(number, 20)
      })), {
      "hello-bff"         = {}
      "hello-orders-api"  = {}
      "hello-catalog-api" = {}
    })
    redis_cache_ttl_seconds = optional(number, 60)
  })
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.settings.apps) : contains(["hello-bff", "hello-orders-api", "hello-catalog-api"], k)])
    error_message = "settings.apps keys must be hello-bff, hello-orders-api or hello-catalog-api."
  }
  validation {
    condition     = alltrue([for a in values(var.settings.apps) : a.max_replicas <= var.settings.replica_ceiling && a.min_replicas <= a.max_replicas])
    error_message = "Every app needs min_replicas <= max_replicas <= replica_ceiling."
  }
  validation {
    condition     = alltrue([for t in values(var.settings.traffic) : t.latest_weight == 100 || t.previous_revision_suffix != null]) && contains(["Single", "Multiple"], var.settings.revision_mode)
    error_message = "traffic.<svc>.latest_weight < 100 requires previous_revision_suffix; revision_mode is Single or Multiple."
  }
  validation {
    condition     = contains(["none", "entra"], var.settings.auth_mode)
    error_message = "auth_mode must be none or entra."
  }
  validation {
    condition     = alltrue([for o in var.settings.cors_allowed_origins : can(regex("^https://[^/*]+$", o))])
    error_message = "cors_allowed_origins entries must be https origins without path or wildcard."
  }
}
