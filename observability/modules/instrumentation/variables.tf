variable "service" {
  description = "Unified service identity of the workload being instrumented (Datadog unified service tagging + ADR-0001 §7 tags)."
  type = object({
    service     = string
    env         = string
    version     = string
    team        = string
    domain      = optional(string, "unknown")
    tier        = optional(string, "unknown")
    application = optional(string, "unknown")
    owner       = optional(string, "unknown")
    region      = optional(string, "unknown")
  })
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{0,99}$", var.service.service)) && can(regex("^[a-z0-9][a-z0-9._-]{0,63}$", var.service.env))
    error_message = "service.service and service.env must be lowercase Datadog tag values ([a-z0-9._-], starting alphanumeric)."
  }
  validation {
    condition     = length(var.service.version) > 0 && !can(regex("[,= ]", var.service.version))
    error_message = "service.version must be non-empty and must not contain ',', '=' or spaces (it is embedded in OTEL_RESOURCE_ATTRIBUTES and DD_TAGS)."
  }
}

variable "runtime" {
  description = "Language runtime: dotnet | python | node | java | browser."
  type        = string
  validation {
    condition     = contains(["dotnet", "python", "node", "java", "browser"], var.runtime)
    error_message = "runtime must be one of dotnet, python, node, java, browser."
  }
}

variable "architecture" {
  description = "Hosting architecture: aks | aca | aci | appservice | functions | vm | vmss | logicapp."
  type        = string
  validation {
    condition     = contains(["aks", "aca", "aci", "appservice", "functions", "vm", "vmss", "logicapp"], var.architecture)
    error_message = "architecture must be one of aks, aca, aci, appservice, functions, vm, vmss, logicapp."
  }
}

variable "telemetry" {
  description = <<-EOT
    The obs-telemetry-transport contract (catalog/contracts/obs-telemetry-transport.v1.schema.json) or an
    equivalent object built by hand for an existing environment. Only non-secret values and Key Vault
    versionless secret IDs are read.
  EOT
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
  validation {
    condition     = can(regex("^https://", var.telemetry.api_key_secret_id))
    error_message = "telemetry.api_key_secret_id must be a Key Vault secret URI (https://<vault>.vault.azure.net/secrets/<name>), never a key value."
  }
  validation {
    condition     = contains(["datadog", "forward"], var.telemetry.fluentbit.sidecar_mode)
    error_message = "telemetry.fluentbit.sidecar_mode must be datadog or forward."
  }
}

variable "container_name" {
  description = "Name of the application container (Kubernetes / Container Apps / ACI). Defaults to service.service."
  type        = string
  default     = null
}

variable "log_file_path" {
  description = "Shared-volume log file for the sidecar route (ACA/ACI). The app writes JSON lines here when LOG_FILE_PATH is set."
  type        = string
  default     = "/var/log/app/app.log"
  validation {
    condition     = can(regex("^(/|[A-Za-z]:\\\\)[A-Za-z0-9._/\\\\ -]+$", var.log_file_path))
    error_message = "log_file_path must be an absolute path (POSIX, or C:\\... on Windows hosts)."
  }
}

variable "otlp_protocol" {
  description = "Override OTEL_EXPORTER_OTLP_PROTOCOL (grpc | http/protobuf). Null = per-architecture default."
  type        = string
  default     = null
  validation {
    condition     = var.otlp_protocol == null || contains(["grpc", "http/protobuf"], coalesce(var.otlp_protocol, "grpc"))
    error_message = "otlp_protocol must be grpc or http/protobuf."
  }
}

variable "trace_sample_ratio" {
  description = "Head sampling ratio for OTEL_TRACES_SAMPLER=parentbased_traceidratio (0..1)."
  type        = number
  default     = 1
  validation {
    condition     = var.trace_sample_ratio >= 0 && var.trace_sample_ratio <= 1
    error_message = "trace_sample_ratio must be between 0 and 1."
  }
}

variable "key_vault_identity_id" {
  description = "User-assigned identity resource ID the app uses to read Key Vault secret references (Container Apps). Null = system-assigned."
  type        = string
  default     = null
}

variable "extra_resource_attributes" {
  description = "Additional OTEL_RESOURCE_ATTRIBUTES (no PII, no high-cardinality values)."
  type        = map(string)
  default     = {}
}

variable "sidecar_resources" {
  description = "CPU/memory for the Fluent Bit sidecar (Container Apps requires valid cpu/memory pairs, e.g. 0.25/0.5Gi)."
  type = object({
    cpu    = optional(number, 0.25)
    memory = optional(string, "0.5Gi")
  })
  default = {}
}
