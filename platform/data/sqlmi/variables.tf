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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-sqlmi)."
  type = object({
    # Disabled by default: first creation in a subnet takes ~4-6 hours and General Purpose 4 vCore
    # costs roughly USD 700+/month when not on the free offer.
    enabled = optional(bool, false)
    entra_admin = optional(object({
      login          = string
      object_id      = string
      principal_type = optional(string, "Group")
    }))
    # Free SQL MI offer (pricingModel = Freemium; one per subscription, 720 vCore-hours/month for
    # 12 months). azurerm cannot set pricingModel, so this path uses AzAPI (README: provider gap).
    free_offer          = optional(bool, false)
    sku_name            = optional(string, "GP_Gen5")
    vcores              = optional(number, 4)
    storage_size_in_gb  = optional(number, 32)
    license_type        = optional(string, "LicenseIncluded")
    pitr_retention_days = optional(number, 7)
    minimum_tls_version = optional(string, "1.2")
    # Weekday business-hours schedule to stop compute outside working hours.
    stop_schedule_enabled = optional(bool, true)
    schedule_timezone     = optional(string, "UTC")
    start_time            = optional(string, "07:00")
    stop_time             = optional(string, "19:00")
  })
  default = {}

  validation {
    condition     = !var.settings.enabled || var.settings.entra_admin != null
    error_message = "entra_admin is required when the managed instance is enabled."
  }
  validation {
    condition     = !var.settings.free_offer || (var.settings.vcores == 4 || var.settings.vcores == 8) && var.settings.storage_size_in_gb <= 64
    error_message = "The free offer allows 4 or 8 vCores and at most 64 GB storage."
  }
}
