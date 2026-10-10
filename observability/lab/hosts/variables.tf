variable "settings" {
  description = "obs-hosts settings."
  type = object({
    agent_version            = optional(string) # null = fleet policy agent.version
    fluent_bit_version       = optional(string, "5.1.3")
    setup_revision           = optional(number, 1) # bump to re-run the installers (e.g. once after the 2.0 upgrade)
    linux_log_glob           = optional(string, "*.log")
    default_linux_log_dir    = optional(string, "/var/log/enterprise-hello")
    default_windows_log_dir  = optional(string, "C:\\ProgramData\\enterprise-hello\\logs")
    sqlvm_os_type            = optional(string, "windows")
    sqlvm_identity_client_id = optional(string) # user-assigned identity on the SQL VM (DSV reader) when the contract has none
    # per-workload application log files (as written by the app deployment, LOG_FILE_PATH); wins over log_dir
    workload_log_paths = optional(map(list(string)), {
      "hello-worker" = ["/var/log/hello-worker/*.log"]
    })
    service_tags = optional(map(map(string)), {}) # host key -> extra tags (service, version, source ...)
  })
  default = {}
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site = string
    api_key_ref  = string
    aggregator = optional(object({
      kind           = optional(string)
      fqdn           = optional(string)
      agent_logs_url = optional(string)
    }))
    env = optional(object({
      fleet = optional(map(string))
    }))
    secrets = object({
      tenant   = optional(string)
      tld      = optional(string)
      base_url = string
    })
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
      id                 = string
      name               = string
      identity_client_id = optional(string)
    })
  })
  default = null
}
