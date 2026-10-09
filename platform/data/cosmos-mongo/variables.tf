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

# Upstream contract: catalog/contracts/foundation-network.v1.schema.json (only the fields used here).
variable "foundation_network" {
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

# Upstream contract: catalog/contracts/foundation-identity.v2.schema.json (only the fields used here).
variable "foundation_identity" {
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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-cosmos-mongo)."
  type = object({
    capacity_mode            = optional(string, "serverless") # serverless | provisioned
    free_tier_enabled        = optional(bool, false)
    autoscale_max_throughput = optional(number, 1000)
    private_endpoint_enabled = optional(bool, true)
    mongo_server_version     = optional(string, "7.0")
    # DSV secret name (<prefix>/<env>/<name>) that holds the connection string, set out-of-band.
    connection_string_secret_name = optional(string, "cosmos-mongo-connection-string")
  })
  default = {}
  validation {
    condition     = contains(["serverless", "provisioned"], var.settings.capacity_mode)
    error_message = "capacity_mode must be serverless or provisioned."
  }
}
