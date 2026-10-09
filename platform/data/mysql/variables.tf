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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-mysql)."
  type = object({
    # Microsoft Entra administrator (user or group). MySQL resolves Entra principals through the
    # server's user-assigned identity, which needs Microsoft Graph read permissions (README).
    entra_admin = object({
      login     = string
      object_id = string
    })
    # Optional existing UAMI for the server's Entra lookups; created here when null.
    server_identity_id    = optional(string)
    network_mode          = optional(string, "vnet") # vnet | private-endpoint
    version               = optional(string, "8.4")
    sku_name              = optional(string, "B_Standard_B1ms")
    storage_size_gb       = optional(number, 20)
    backup_retention_days = optional(number, 7)
    # Bump to rotate the (write-only, never stored) break-glass administrator password.
    admin_password_version = optional(number, 1)
    # Secret name convention for the DBM native user created by obs-dbm (value never set here).
    dbm_password_secret_name = optional(string, "dbm-mysql-password")
  })

  validation {
    condition     = contains(["vnet", "private-endpoint"], var.settings.network_mode)
    error_message = "network_mode must be vnet or private-endpoint."
  }
  validation {
    condition     = var.settings.backup_retention_days >= 1 && var.settings.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35."
  }
}
