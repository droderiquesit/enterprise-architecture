variable "service" {
  description = "Unified service identity (Datadog unified service tagging + ADR-0001 §7 tags)."
  type = object({
    name    = string # DD_SERVICE, e.g. hello-bff
    version = string # DD_VERSION (artifact version)
    commit  = optional(string, "unknown")
    env     = string
    team    = string
    owner   = optional(string, "unknown")
    domain  = optional(string, "unknown")
    tier    = optional(string, "unknown")
    region  = optional(string, "unknown")
  })
}

variable "runtime" {
  description = "dotnet | python"
  type        = string
  validation {
    condition     = contains(["dotnet", "python"], var.runtime)
    error_message = "runtime must be dotnet or python."
  }
}

variable "architecture" {
  description = "aks | aca | aci | appservice | functions | vm | vmss | logicapp (observability/modules/instrumentation)."
  type        = string
}

variable "telemetry" {
  description = "obs-telemetry-transport contract (catalog/contracts/obs-telemetry-transport.v1.schema.json), fields used by the instrumentation hook."
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

variable "identity_client_id" {
  description = "Client id of the workload's user-assigned identity (AZURE_CLIENT_ID). Null = not set."
  type        = string
  default     = null
}

variable "key_vault_identity_id" {
  description = "User-assigned identity resource id used to resolve Key Vault secret references (Container Apps)."
  type        = string
  default     = null
}

variable "faults" {
  description = "Fault injection wiring (ADR §9). enabled => FAULTS_ENABLED=true (lab only); token_secret_id => FAULT_TOKEN from Key Vault."
  type = object({
    enabled         = optional(bool, false)
    token_secret_id = optional(string)
  })
  default = {}
  validation {
    condition     = var.faults.token_secret_id == null || can(regex("^https://[^/]+/secrets/[A-Za-z0-9-]+$", coalesce(var.faults.token_secret_id, "x")))
    error_message = "faults.token_secret_id must be a versionless Key Vault secret id."
  }
}

variable "port" {
  description = "HTTP port the process listens on (PORT). Null = not an HTTP service / platform-defined."
  type        = number
  default     = 8080
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "trace_sample_ratio" {
  type    = number
  default = 1
}

variable "otlp_protocol" {
  description = "Override OTEL_EXPORTER_OTLP_PROTOCOL (null = per-architecture default from the hook)."
  type        = string
  default     = null
}

variable "extra_env" {
  description = "Service-specific, NON-secret environment (connection hints, URLs). Must not contain secret values."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Service-specific secret environment: name -> versionless Key Vault secret id."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for v in values(var.secret_env) : can(regex("^https://[^/]+/secrets/[A-Za-z0-9-]+$", v))])
    error_message = "secret_env values must be versionless Key Vault secret ids (https://<vault>/secrets/<name>)."
  }
}

variable "extra_resource_attributes" {
  type    = map(string)
  default = {}
}
