# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "obs_prereqs" {
  description = "obs-prereqs contract v1 (required)."
  type = object({
    datadog_site = string
    rum = object({
      applications = map(object({
        application_id             = string
        client_token               = string
        site                       = string
        service                    = optional(string)
        session_sample_rate        = number
        session_replay_sample_rate = number
        default_privacy_level      = optional(string, "mask-user-input")
        track_user_interactions    = optional(bool, true)
      }))
    })
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v1 (required)."
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

variable "deploy_core_aks" {
  description = "deploy-core-aks contract v1 (optional; null when the producer is not enabled)."
  type = object({
    public_api = optional(object({
      origin    = optional(string)
      base_path = optional(string, "/api")
    }))
    apps = optional(map(object({
      url = optional(string)
    })), {})
  })
  default = null
}

variable "deploy_core_aca" {
  description = "deploy-core-aca contract v1 (optional; null when the producer is not enabled)."
  type = object({
    public_api = optional(object({
      origin    = optional(string)
      base_path = optional(string, "/api")
    }))
    apps = optional(map(object({
      url = optional(string)
    })), {})
  })
  default = null
}

variable "foundation_edge" {
  description = "foundation-edge contract v1 (optional; null when the producer is not enabled)."
  type = object({
    front_door = optional(object({
      enabled           = bool
      endpoint_hostname = optional(string)
    }))
    apim = optional(object({
      enabled     = bool
      gateway_url = optional(string)
    }))
  })
  default = null
}
