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
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-table-storage)."
  type = object({
    replication_type         = optional(string, "LRS")
    private_endpoint_enabled = optional(bool, true)
  })
  default = {}
}
