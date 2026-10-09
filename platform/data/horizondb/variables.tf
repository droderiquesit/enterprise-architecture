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
    secret_ids    = optional(map(string), {}) # versionless Key Vault secret IDs (values set out-of-band)
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-horizondb)."
  type = object({
    # Azure HorizonDB is in preview: disabled by default (status `blocked` until preview access is confirmed).
    enabled = optional(bool, false)
    # Set to true only after confirming the subscription can create Microsoft.HorizonDb/clusters in the
    # region (resource provider registered, preview terms accepted, region on the preview list).
    preview_access_confirmed = optional(bool, false)
    api_version              = optional(string, "2026-05-01-preview")
    postgres_version         = optional(string, "17") # only v17 is offered in preview
    vcores                   = optional(number, 2)
    replica_count            = optional(number, 1)
    zone_placement_policy    = optional(string, "BestEffort")
    entra_admin = optional(object({
      object_id      = string
      principal_name = string
      principal_type = optional(string, "Group")
    }))
    # Private Link: the group ID is not documented yet; read it from
    # GET <cluster id>/privateLinkResources and set it here to create the private endpoint.
    private_endpoint_group_id = optional(string)
    admin_password_version    = optional(number, 1)
  })
  default = {}

  validation {
    condition     = !var.settings.enabled || var.settings.entra_admin != null
    error_message = "entra_admin is required when HorizonDB is enabled."
  }
}
