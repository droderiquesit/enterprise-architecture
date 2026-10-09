variable "settings" {
  description = "obs-hosts settings."
  type = object({
    agent_version       = optional(string, "7.84.2")
    fluent_bit_version  = optional(string, "5.1.3")
    api_key_secret_name = optional(string, "datadog-api-key")
    # VERSIONED Key Vault secret whose value is {"api_key":"<key>"} for the extension's
    # protectedSettingsFromKeyVault (vault needs enabled_for_deployment). Null -> the API key is read with
    # a data source and passed as a protected setting (stored, encrypted, in state: documented exception).
    agent_protected_settings_secret_url = optional(string)
    linux_log_glob                      = optional(string, "*.log")
    default_linux_log_dir               = optional(string, "/var/log/enterprise-hello")
    default_windows_log_dir             = optional(string, "C:\\ProgramData\\enterprise-hello\\logs")
    sqlvm_os_type                       = optional(string, "windows")
    service_tags                        = optional(map(map(string)), {}) # host key -> extra tags (service, version, source ...)
  })
  default = {}
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site      = string
    api_key_secret_id = string
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract (fields used)."
  type = object({
    key_vault_id = string
  })
}

variable "platform_vm" {
  description = "platform-vm contract (optional)."
  type = object({
    location = optional(string)
    vms = map(object({
      id                 = string
      name               = string
      os_type            = string
      workload           = optional(string)
      identity_client_id = optional(string)
      log_dir            = optional(string)
    }))
  })
  default = null
}

variable "platform_vmss" {
  description = "platform-vmss contract (optional)."
  type = object({
    location = optional(string)
    scale_sets = map(object({
      id                 = string
      name               = string
      os_type            = string
      workload           = optional(string)
      identity_client_id = optional(string)
      log_dir            = optional(string)
    }))
  })
  default = null
}

variable "platform_db_sqlvm" {
  description = "platform-db-sqlvm contract (optional): the SQL Server VM gets the Agent only (no app logs)."
  type = object({
    vm = object({
      id   = string
      name = string
    })
  })
  default = null
}
