# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "platform_aks" {
  description = "platform-aks contract v1 (required)."
  type = object({
    resource_group_name = string
    cluster_id          = string
    cluster_name        = string
    oidc_issuer_url     = string
    access = object({
      private_cluster     = bool
      fqdn                = optional(string)
      private_fqdn        = optional(string)
      entra_server_app_id = optional(string, "6dae42f8-4368-4678-94ff-3960e28e3630")
    })
    workload_identities = map(object({
      namespace       = string
      service_account = string
      client_id       = string
    }))
  })
}

variable "platform_shared" {
  description = "platform-shared contract v1 (required)."
  type = object({
    acr_id           = string
    acr_login_server = string
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

variable "platform_db_sql" {
  description = "platform-db-sql contract v1 (required)."
  type = object({
    server = object({
      fqdn = string
      port = optional(number, 1433)
    })
    databases = map(object({
      name = string
      id   = optional(string)
    }))
  })
}

variable "platform_db_postgresql" {
  description = "platform-db-postgresql contract v1 (required)."
  type = object({
    server = object({
      fqdn = string
      port = optional(number, 5432)
    })
    databases = map(object({
      name = string
      id   = optional(string)
    }))
    elastic_cluster = optional(object({
      id       = string
      fqdn     = string
      port     = optional(number, 5432)
      database = optional(string, "adapter")
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

variable "platform_db_redis" {
  description = "platform-db-redis contract v1 (optional; null when the producer is not enabled)."
  type = object({
    cache = object({
      id       = string
      hostname = string
      port     = optional(number, 10000)
    })
  })
  default = null
}

variable "obs_kubernetes" {
  description = "obs-kubernetes contract v2 (optional; null when the producer is not enabled). Not read today."
  type = object({
    namespace     = optional(string)
    log_collector = optional(string)
    agent = optional(object({
      local_service = optional(string)
      logs_enabled  = optional(bool)
    }))
  })
  default = null
}
