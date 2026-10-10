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
    # further tag-policy identity (observability/config/tag-policy.yaml)
    application = optional(string, "enterprise-hello")
    managed_by  = optional(string, "terraform")
    cost_center = optional(string)
    component   = optional(string)
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
  description = "obs-telemetry-transport contract v3 (catalog/contracts/obs-telemetry-transport.v3.schema.json), fields used by the instrumentation hook."
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
    # Observability Pipelines Worker (Datadog Agent source URL for the ACI Agent / serverless-init sidecars)
    aggregator = optional(object({
      kind           = optional(string)
      fqdn           = optional(string)
      pipeline_id    = optional(string)
      agent_logs_url = optional(string)
      log_pipeline   = optional(string)
    }))
    env = optional(map(map(string)), {})
  })
}

variable "identity_client_id" {
  description = "Client id of the workload's user-assigned identity (AZURE_CLIENT_ID). Null = not set."
  type        = string
  default     = null
}

variable "faults" {
  description = "Fault injection wiring (ADR §9). enabled => FAULTS_ENABLED=true (lab only); token_ref => FAULT_TOKEN = dsv:// reference (resolved by the app)."
  type = object({
    enabled   = optional(bool, false)
    token_ref = optional(string)
  })
  default = {}
  validation {
    condition     = var.faults.token_ref == null || can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", coalesce(var.faults.token_ref, "x")))
    error_message = "faults.token_ref must be a Delinea DSV reference (dsv://<path>#<element>)."
  }
}

variable "port" {
  description = "HTTP port the process listens on (PORT). Null = not an HTTP service / platform-defined."
  type        = number
  default     = 8080
}

variable "log_level" {
  description = "LOG_LEVEL of the service (debug | info | warning | error)."
  type        = string
  default     = "info"
}

variable "trace_sample_ratio" {
  description = "Trace sampling ratio 0..1 (OTEL_TRACES_SAMPLER_ARG via the instrumentation hook)."
  type        = number
  default     = 1
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
  validation {
    condition     = !anytrue([for k, v in var.extra_env : startswith(v, "dsv://")])
    error_message = "extra_env must not carry dsv:// references; put secret settings in secret_env."
  }
}

variable "secret_env" {
  description = "Service-specific secret settings: name -> Delinea DSV reference (dsv://<path>#<element>). The app resolves them at start-up."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for v in values(var.secret_env) : can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", v))])
    error_message = "secret_env values must be Delinea DSV references (dsv://<path>#<element>), never values."
  }
}

variable "extra_resource_attributes" {
  description = "Additional OTEL_RESOURCE_ATTRIBUTES entries (name -> value) of this workload."
  type        = map(string)
  default     = {}
}

variable "tag_policy" {
  description = "Decoded tag policy (null = observability package default config/tag-policy.yaml)."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional Datadog tags of this workload (the policy's canonical keys win)."
  type        = map(string)
  default     = {}
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = observability package default config/fleet-policy.yaml): APM mode, profiler, DSM, DBM propagation, log pipeline."
  type        = any
  default     = null
}

variable "apm" {
  description = "Per-workload APM overrides (fleet policy apm section shape), e.g. { mode = \"otel\" }."
  type        = any
  default     = null
}

variable "logs" {
  description = "Per-workload log overrides (fleet policy logs section shape), e.g. { collector = \"azure\" } (Container Apps jobs: console logs via diagnostic settings). Null = policy."
  type        = any
  default     = null
}

variable "agent_sidecar" {
  description = "ACI Datadog Agent sidecar overrides (image, cpu, memory_gb, hostname); null fields = fleet policy (pinned Agent image, 0.25 vCPU / 0.5 GB)."
  type = object({
    image     = optional(string)
    cpu       = optional(number)
    memory_gb = optional(number)
    hostname  = optional(string)
  })
  default = {}
}

variable "serverless_init" {
  description = "Container Apps serverless-init sidecar (fleet policy default for aca: traces, DogStatsD, app log file): Azure context (subscription_id, resource_group) and optional image/sizing. The Datadog API key is read from Delinea DSV by the dsv-fetch binary in the sidecar."
  type        = any
  default     = {}
}

variable "profiling" {
  description = "Per-workload Continuous Profiler overrides (fleet policy profiling section shape), e.g. { enabled = false }."
  type        = any
  default     = null
}

variable "os_type" {
  description = "linux | windows (App Service / Functions plan, VM)."
  type        = string
  default     = "linux"
}
