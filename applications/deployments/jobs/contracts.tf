# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "platform_containerapps" {
  description = "platform-containerapps contract v1 (required)."
  type = object({
    resource_group_name    = string
    location               = optional(string)
    environment_id         = string
    default_domain         = string
    ingress_mode           = string
    workload_profiles      = list(string)
    dedicated_profile_name = optional(string)
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

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract v1 (required)."
  type = object({
    datadog_site      = string
    api_key_secret_id = string
    otlp = object({
      grpc_endpoint            = string
      http_endpoint            = string
      headers_secret_id        = optional(string)
      default_protocol         = optional(string, "http/protobuf")
      node_agent_grpc_port     = optional(number, 4317)
      node_agent_http_port     = optional(number, 4318)
      host_agent_grpc_endpoint = optional(string, "http://localhost:4317")
    })
    fluentbit = object({
      forward_host                 = string
      forward_port                 = number
      sidecar_image                = optional(string, "fluent/fluent-bit:5.1.3")
      sidecar_config               = optional(string)
      sidecar_forward_config       = optional(string)
      sidecar_parsers              = optional(string)
      sidecar_lua                  = optional(string)
      sidecar_mode                 = optional(string, "datadog")
      logs_intake_host             = optional(string)
      forward_shared_key_secret_id = optional(string)
    })
    batch_log_setup = optional(object({
      script_gzip_base64 = string
      script_sha256      = string
      fluent_bit_version = string
      log_paths_template = string
      identity_env       = optional(string, "EH_IDENTITY_CLIENT_ID")
      log_paths_env      = optional(string, "EH_LOG_PATHS")
    }))
    env = optional(map(map(string)), {})
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v1 (required)."
  type = object({
    key_vault_id  = string
    key_vault_uri = string
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
    secret_ids = map(string)
  })
}

variable "platform_batch" {
  description = "platform-batch contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account_name     = string
    account_endpoint = string
    pool = object({
      id     = string
      name   = string
      python = optional(string, "python3.13")
    })
    identity = object({
      id        = string
      client_id = string
    })
    auto_storage = object({
      name               = string
      blob_endpoint      = string
      packages_container = string
      output_container   = string
    })
  })
  default = null
}

variable "deploy_core_aks" {
  description = "deploy-core-aks contract v1 (optional; null when the producer is not enabled)."
  type = object({
    public_api = optional(object({
      origin    = optional(string)
      base_path = optional(string, "/api")
    }))
    apps = optional(map(object({
      url = optional(string)
    })), {})
  })
  default = null
}

variable "deploy_core_aca" {
  description = "deploy-core-aca contract v1 (optional; null when the producer is not enabled)."
  type = object({
    public_api = optional(object({
      origin    = optional(string)
      base_path = optional(string, "/api")
    }))
    apps = optional(map(object({
      url = optional(string)
    })), {})
  })
  default = null
}

variable "deploy_frontend" {
  description = "deploy-frontend contract v1 (optional; null when the producer is not enabled)."
  type = object({
    url = optional(string)
  })
  default = null
}

variable "deploy_durable" {
  description = "deploy-durable contract v1 (optional; null when the producer is not enabled). function_app.hostname -> DURABLE_API_URL."
  type = object({
    function_app = object({
      hostname = string
    })
  })
  default = null
}
