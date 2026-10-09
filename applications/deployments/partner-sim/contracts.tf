# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "foundation_network" {
  description = "foundation-network contract v1 (required)."
  type = object({
    resource_group_name  = string
    location             = string
    internal_dns_zone    = optional(string)
    internal_dns_zone_id = optional(string)
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
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
