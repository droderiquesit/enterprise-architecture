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
    grant_key_vault_secrets_user   = optional(bool, false) # foundation-identity already grants obs-collector
  })
  default = {}
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
  description = "foundation-identity contract (fields used)."
  type = object({
    key_vault_id  = string
    key_vault_uri = string
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
    secret_ids = map(string)
  })
}

variable "platform_containerapps" {
  description = "platform-containerapps contract (fields used)."
  type = object({
    environment_id    = string
    default_domain    = string
    workload_profiles = list(string)
  })
}
