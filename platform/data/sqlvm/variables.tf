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
    # DSV secret names (<prefix>/<env>/<name>); contracts carry only dsv:// references.
    admin_secret_name     = optional(string, "sqlvm-admin-password")
    dbadapter_secret_name = optional(string, "sqlvm-dbadapter-password")
    host_identity_name    = optional(string, "obs-dbm") # user-assigned identity for host agents (DSV auth)
    dbm_secret_name       = optional(string, "dbm-sqlvm-password")
  })
  default = {}
}

# Secret inputs from Delinea DSV (pipeline: tools/secrets/fetch.py -> TF_VAR_admin_password / TF_VAR_dbadapter_password).
# Not ephemeral: the receiving arguments have no write-only form, so the values are stored in state (README).
variable "admin_password" {
  description = "Local administrator + SQL connectivity password (DSV sqlvm-admin-password)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123 && !can(regex("['\"]", var.admin_password))
    error_message = "admin_password: 12-123 characters, no quotes (DSV sqlvm-admin-password)."
  }
}

variable "dbadapter_password" {
  description = "SQL login `dbadapter` password (DSV sqlvm-dbadapter-password; the adapter reads the same path at runtime)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.dbadapter_password) >= 12 && !can(regex("['\"]", var.dbadapter_password))
    error_message = "dbadapter_password: at least 12 characters, no quotes (DSV sqlvm-dbadapter-password)."
  }
}
