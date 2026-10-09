variable "service" {
  description = "Unified service identity of the workload being instrumented (Datadog unified service tagging + ADR-0001 §7 tags)."
  type = object({
    service     = string
    env         = string
    version     = string
    team        = string
    domain      = optional(string)
    tier        = optional(string)
    application = optional(string)
    owner       = optional(string)
    region      = optional(string)
    managed_by  = optional(string)
    cost_center = optional(string)
    component   = optional(string)
    # any further canonical key of your tag policy (e.g. business_unit) -> value
    extra = optional(map(string), {})
  })
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{0,99}$", var.service.service)) && length(trimspace(var.service.env)) > 0
    error_message = "service.service must be a lowercase Datadog tag value ([a-z0-9._-], starting alphanumeric); service.env must be set (the tag policy value_map / normalisation applies to it)."
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
    The obs-telemetry-transport contract v2 (catalog/contracts/obs-telemetry-transport.v2.schema.json) or an
    equivalent object built by hand for an existing environment. Only non-secret values and Delinea DSV
    references (dsv://<path>#<element>) are read; secret VALUES never pass through this module.
      secrets : DSV runtime env for workloads (DSV_TENANT/DSV_TLD/DSV_BASE_URL/DSV_AUTH) and the dsv-fetch
                helper image used as init container (ACA) / refresher container (ACI) for third-party sidecars.
  EOT
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
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.telemetry.api_key_ref))
    error_message = "telemetry.api_key_ref must be a Delinea DSV reference (dsv://<path>#<element>), never a key value."
  }
  validation {
    condition = alltrue([for r in compact([try(var.telemetry.otlp.headers_ref, null), try(var.telemetry.fluentbit.forward_shared_key_ref, null)]) :
    can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", r))])
    error_message = "telemetry.otlp.headers_ref and telemetry.fluentbit.forward_shared_key_ref must be dsv:// references."
  }
  validation {
    condition     = var.telemetry.secrets.provider == "delinea-dsv" && contains(["azure", "client_credentials", "none"], var.telemetry.secrets.auth) && can(regex("^https?://", var.telemetry.secrets.base_url))
    error_message = "telemetry.secrets: provider delinea-dsv, auth azure|client_credentials|none, base_url http(s)://... (e.g. https://<tenant>.secretsvaultcloud.com/v1)."
  }
  validation {
    condition     = contains(["datadog", "forward"], var.telemetry.fluentbit.sidecar_mode)
    error_message = "telemetry.fluentbit.sidecar_mode must be datadog or forward."
  }
  validation {
    condition     = !contains(["aca", "aci"], var.architecture) || var.runtime == "browser" || var.telemetry.secrets.fetch_image != null
    error_message = "ACA/ACI sidecars read their keys with the dsv-fetch helper: telemetry.secrets.fetch_image is required (digest-pinned dsv-fetch image)."
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

variable "identity_client_id" {
  description = "Client id of the workload's user-assigned managed identity: AZURE_CLIENT_ID of the dsv-fetch helper (and of the app). Null = not set (system identity / caller sets it)."
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

variable "fetch_resources" {
  description = "CPU/memory of the dsv-fetch init container (ACA) / refresher container (ACI)."
  type = object({
    cpu       = optional(number, 0.25)
    memory    = optional(string, "0.5Gi")
    aci_cpu   = optional(number, 0.1)
    aci_mem   = optional(number, 0.2)
    refresh_s = optional(number, 3600)
  })
  default = {}
}

variable "tag_policy" {
  description = "Decoded tag policy (schemas/tag-policy.v1.schema.json); null = the package default config/tag-policy.yaml. Use the same policy in every module of a root."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional Datadog tags for this workload (key -> value), merged over the policy's static tags (canonical keys win)."
  type        = map(string)
  default     = {}
}
