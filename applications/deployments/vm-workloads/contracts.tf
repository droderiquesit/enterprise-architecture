# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "platform_messaging" {
  description = "platform-messaging contract v1 (required)."
  type = object({
    namespace_id   = string
    namespace_name = string
    fqdn           = string
    topic = object({
      name = string
      id   = string
    })
    subscriptions = map(object({
      name = string
      id   = string
    }))
    queues = map(object({
      name = string
      id   = string
    }))
  })
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract v3 (required). Secrets are Delinea DSV references (dsv://...), never values."
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      provider    = optional(string, "delinea-dsv")
      tenant      = optional(string)
      tld         = optional(string, "com")
      base_url    = string
      auth        = optional(string, "azure")
      fetch_image = optional(string)
      env_file    = optional(string, "/dsv-secrets/fluentbit-env.yaml")
    })
    otlp = object({
      grpc_endpoint            = string
      http_endpoint            = string
      headers_ref              = optional(string)
      default_protocol         = optional(string, "http/protobuf")
      node_agent_grpc_port     = optional(number, 4317)
      node_agent_http_port     = optional(number, 4318)
      host_agent_grpc_endpoint = optional(string, "http://localhost:4317")
    })
    fluentbit = object({
      forward_host           = string
      forward_port           = number
      sidecar_image          = optional(string, "fluent/fluent-bit:5.1.3")
      sidecar_config         = optional(string)
      sidecar_forward_config = optional(string)
      sidecar_parsers        = optional(string)
      sidecar_lua            = optional(string)
      sidecar_mode           = optional(string, "datadog")
      logs_intake_host       = optional(string)
      forward_shared_key_ref = optional(string)
    })
    env = optional(map(map(string)), {})
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (required): identities + Delinea DSV secrets block (refs). No Key Vault."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
      secrets      = optional(list(string), [])
    }))
    secrets = object({
      provider  = optional(string, "delinea-dsv")
      tenant    = optional(string)
      tld       = optional(string, "com")
      base_url  = optional(string)
      base_path = string
      refs      = optional(map(string), {})
    })
  })
}

variable "platform_vm" {
  description = "platform-vm contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name = string
    location            = optional(string)
    vms = map(object({
      id                 = string
      name               = string
      os_type            = string
      private_ip         = optional(string)
      workload           = string
      identity_id        = optional(string)
      identity_client_id = optional(string)
      app_root           = optional(string)
      log_dir            = optional(string)
    }))
  })
  default = null
}

variable "platform_vmss" {
  description = "platform-vmss contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name = string
    location            = optional(string)
    scale_sets = map(object({
      id                 = string
      name               = string
      orchestration_mode = string
      upgrade_mode       = optional(string, "Manual")
      workload           = string
      identity_id        = optional(string)
      identity_client_id = optional(string)
      app_root           = optional(string, "/opt/hello")
      log_dir            = optional(string, "/var/log/hello")
    }))
  })
  default = null
}

variable "platform_db_table_storage" {
  description = "platform-db-table-storage contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
    })
    databases = map(object({
      name = string
    }))
  })
  default = null
}

variable "platform_db_cosmos_nosql" {
  description = "platform-db-cosmos-nosql contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}
