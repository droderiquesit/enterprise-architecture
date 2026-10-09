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

# Upstream contract: catalog/contracts/foundation-identity.v1.schema.json (only the fields used here).
variable "foundation_identity" {
  type = object({
    key_vault_id  = string
    key_vault_uri = string
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-cosmos-nosql)."
  type = object({
    capacity_mode            = optional(string, "serverless") # serverless | provisioned
    free_tier_enabled        = optional(bool, false)          # provisioned only; one per subscription
    autoscale_max_throughput = optional(number, 1000)         # provisioned only (autoscale minimum max RU/s)
    private_endpoint_enabled = optional(bool, true)
    consistency_level        = optional(string, "Session")
  })
  default = {}
  validation {
    condition     = contains(["serverless", "provisioned"], var.settings.capacity_mode)
    error_message = "capacity_mode must be serverless or provisioned."
  }
}
