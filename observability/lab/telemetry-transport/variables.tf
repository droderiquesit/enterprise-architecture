variable "settings" {
  description = "obs-telemetry-transport settings (environments/<env>/environment.yaml components.obs-telemetry-transport)."
  type = object({
    datadog_site                   = optional(string, "datadoghq.com")
    api_key_secret_name            = optional(string, "datadog-api-key")
    forward_shared_key_secret_name = optional(string, "fluentbit-shared-key")
    collector_identity_key         = optional(string, "obs-collector")
    event_hub_mode                 = optional(string, "create")
    event_hub_capacity             = optional(number, 1)
    event_hub_private_endpoint     = optional(bool, true)
    event_hub_activity_logs_hub    = optional(string, "activity-logs")             # "" = share the platform-logs hub
    eventhub_listen_secret_name    = optional(string, "eventhub-fluentbit-listen") # DSV secret written by tools/secrets/publish.py
    fetch_artifact                 = optional(string, "img-dsv-fetch")             # artifacts key of the dsv-fetch image
    batch_log_setup_enabled        = optional(bool, true)                          # publish the Batch Fluent Bit setup script in the contract
    aggregator_hosting             = optional(string, "container_app")
    gateway_hosting                = optional(string, "container_app")
    gateway_distribution           = optional(string, "upstream")
    gateway_sampling               = optional(string, "probabilistic")
    gateway_sampling_percentage    = optional(number, 100)
    gateway_otlp_logs              = optional(string, "drop")
    gateway_max_replicas           = optional(number, 2)
    aggregator_max_replicas        = optional(number, 2)
    workload_profile_name          = optional(string) # null = first profile of platform_containerapps
    sidecar_mode                   = optional(string, "datadog")
    aca_console_allow              = optional(list(string)) # null = ["<prefix>-caj-*"] (ACA jobs have no sidecar)
  })
  default = {}
  validation {
    condition     = contains(["create", "existing", "none"], var.settings.event_hub_mode) && contains(["container_app", "none"], var.settings.aggregator_hosting) && contains(["container_app", "none"], var.settings.gateway_hosting)
    error_message = "event_hub_mode: create|existing|none; aggregator_hosting/gateway_hosting: container_app|none."
  }
  validation {
    condition     = var.settings.event_hub_capacity >= 1 && var.settings.event_hub_capacity <= 2 && var.settings.gateway_max_replicas <= 5 && var.settings.aggregator_max_replicas <= 5
    error_message = "Lab cost ceiling: event_hub_capacity 1-2 TU, gateway/aggregator max_replicas <= 5 (raise in the portable module for production)."
  }
}

variable "foundation_network" {
  description = "foundation-network contract (fields used)."
  type = object({
    subnets = map(object({
      id   = string
      name = string
    }))
    private_dns_zones = map(object({
      id   = string
      name = string
    }))
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): identities + Delinea DSV secrets block (no Key Vault)."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
      secrets      = optional(list(string), [])
    }))
    secrets = object({
      provider  = string
      tenant    = optional(string)
      tld       = optional(string, "com")
      base_url  = string
      base_path = string
      refs      = map(string)
    })
  })
  validation {
    condition     = var.foundation_identity.secrets.provider == "delinea-dsv"
    error_message = "foundation_identity.secrets.provider must be delinea-dsv (ADR-0001 section 14)."
  }
}

variable "platform_containerapps" {
  description = "platform-containerapps contract (fields used)."
  type = object({
    environment_id    = string
    default_domain    = string
    workload_profiles = list(string)
  })
}

variable "artifacts" {
  description = "Immutable build outputs keyed by artifact component id (tools/deploy/artifacts.py tfvars); this root uses img-dsv-fetch (digest-pinned)."
  type = map(object({
    name    = optional(string)
    image   = optional(string)
    digest  = optional(string)
    version = optional(string)
    commit  = optional(string)
    tag     = optional(string)
  }))
  default = {}
  validation {
    condition = alltrue([for a in values(var.artifacts) : a.image == null || can(regex(
      "^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", coalesce(a.image, "x")
    ))])
    error_message = "artifacts[*].image must be digest-pinned (<registry>/<repo>@sha256:<64 hex>)."
  }
}
