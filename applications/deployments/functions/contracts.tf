# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "platform_functions" {
  description = "platform-functions contract v1 (required)."
  type = object({
    resource_group_name        = string
    location                   = optional(string)
    flex_integration_subnet_id = optional(string)
    integration_subnet_id      = optional(string)
    flex = map(object({
      plan_id                  = string
      identity                 = string
      storage_account_name     = string
      blob_endpoint            = optional(string)
      queue_endpoint           = optional(string)
      table_endpoint           = optional(string)
      deployment_container_url = string
    }))
    durable_storage = optional(object({
      storage_account_name = string
      blob_endpoint        = optional(string)
      queue_endpoint       = optional(string)
      table_endpoint       = optional(string)
    }))
    premium = optional(object({
      plan_id              = string
      storage_account_name = string
      identity             = optional(string, "hello-functions")
    }))
    consumption_windows = optional(object({
      plan_id              = string
      storage_account_name = string
      identity             = optional(string, "hello-durable")
    }))
  })
}

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
  description = "obs-telemetry-transport contract v2 (required). Secrets are Delinea DSV references (dsv://...), never values."
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

variable "platform_appservice" {
  description = "platform-appservice contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name   = string
    location              = optional(string)
    integration_subnet_id = string
    plans = map(object({
      id      = string
      name    = string
      os_type = string
      sku     = string
    }))
    functions_dedicated_plan = optional(string)
    logicapps_storage = optional(object({
      id            = string
      name          = string
      blob_endpoint = optional(string)
    }))
  })
  default = null
}

variable "platform_containerapps" {
  description = "platform-containerapps contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name    = string
    location               = optional(string)
    environment_id         = string
    default_domain         = string
    ingress_mode           = string
    workload_profiles      = list(string)
    dedicated_profile_name = optional(string)
  })
  default = null
}

variable "platform_shared" {
  description = "platform-shared contract v1 (optional; null when the producer is not enabled)."
  type = object({
    acr_id           = string
    acr_login_server = string
  })
  default = null
}

variable "foundation_network" {
  description = "foundation-network contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name  = string
    location             = string
    internal_dns_zone    = optional(string)
    internal_dns_zone_id = optional(string)
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
  })
  default = null
}

variable "platform_db_ledger" {
  description = "platform-db-ledger contract v1 (optional; null when the producer is not enabled)."
  type = object({
    ledger = object({
      id                        = string
      name                      = string
      ledger_endpoint           = string
      identity_service_endpoint = optional(string)
    })
    databases = map(object({
      name = string
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
