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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-sqlvm)."
  type = object({
    vm_size = optional(string, "Standard_B2ms")
    # SQL Server 2022 Developer on Windows Server 2022 (Gen2): free SQL license for dev/test.
    image = optional(object({
      publisher = optional(string, "MicrosoftSQLServer")
      offer     = optional(string, "sql2022-ws2022")
      sku       = optional(string, "sqldev-gen2")
      version   = optional(string, "latest")
    }), {})
    os_disk_type   = optional(string, "StandardSSD_LRS")
    data_disk_type = optional(string, "StandardSSD_LRS")
    data_disk_gb   = optional(number, 32)
    log_disk_gb    = optional(number, 32)
    # Daily auto-shutdown (DevTest Labs global schedule).
    auto_shutdown = optional(object({
      enabled  = optional(bool, true)
      time     = optional(string, "1900")
      timezone = optional(string, "UTC")
    }), {})
    # Key Vault secret names (foundation-identity vault). Values are generated here and written
    # write-only; contracts carry only versionless IDs.
    admin_secret_name     = optional(string, "sqlvm-admin-password")
    dbadapter_secret_name = optional(string, "sqlvm-dbadapter-password")
    dbm_secret_name       = optional(string, "dbm-sqlvm-password")
    secret_version        = optional(number, 1)
  })
  default = {}
}
