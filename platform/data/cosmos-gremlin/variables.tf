variable "environment" {
  description = "Environment globals (ADR-0001 §6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "foundation_network" {
  description = "foundation-network contract v1 (catalog/contracts/foundation-network.v1.schema.json), only the fields used here."
  type = object({
    resource_group_name = string
    location            = string
    spoke_vnet_id       = string
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (catalog/contracts/foundation-identity.v2.schema.json), only the fields used here."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
    # Delinea DSV references (ADR-0001 section 14): dsv://<base_path>/<name>#value - never values.
    secrets = object({
      base_path = string
      refs      = optional(map(string), {})
    })
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-cosmos-gremlin)."
  type = object({
    capacity_mode            = optional(string, "serverless") # serverless | provisioned
    free_tier_enabled        = optional(bool, false)
    autoscale_max_throughput = optional(number, 1000)
    private_endpoint_enabled = optional(bool, true)
    key_secret_name          = optional(string, "cosmos-gremlin-key")
  })
  default = {}
  validation {
    condition     = contains(["serverless", "provisioned"], var.settings.capacity_mode)
    error_message = "capacity_mode must be serverless or provisioned."
  }
}
