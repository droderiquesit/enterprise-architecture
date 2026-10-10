variable "name" {
  description = "Pipeline name in Datadog (one pipeline per environment, e.g. eh-dev-logs)."
  type        = string
}

variable "env" {
  description = "Environment name (env tag default for logs that arrive without one)."
  type        = string
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default). Its static tags, aliases and value maps are enforced on every log."
  type        = any
  default     = null
}

variable "default_tags" {
  description = "Tags added when a log carries none for the key (rendered by modules/tagging for the environment, e.g. env, region, managed_by, application + policy static tags)."
  type        = map(string)
  default     = {}
}

variable "sources" {
  description = <<-EOT
    Worker sources. fluent_bit: Fluent Bit forward protocol from edge collectors (ACA/ACI sidecars, Batch nodes) on
    24224; datadog_agent: Datadog Agents (AKS nodes, VMs) on 8282; opentelemetry: OTLP logs (off: application logs
    never travel over OTLP); eventhub: Azure Event Hubs through the Kafka endpoint (platform, Activity Log, app-console
    hubs) - replaces the Fluent Bit aggregator's kafka input.
  EOT
  type = object({
    fluent_bit    = optional(bool, true)
    datadog_agent = optional(bool, true)
    opentelemetry = optional(bool, false)
    eventhub = optional(object({
      enabled   = optional(bool, true)
      topics    = list(string)
      group_id  = optional(string, "observability-pipelines")
      app_topic = optional(string, "app-logs")
    }))
  })
  default = {}
}

variable "fluent_tls" {
  description = "TLS for the fluent_bit source (server certificate paths inside the worker; files written by dsv-fetch). Null = plaintext inside the VNet (internal ingress only)."
  type = object({
    crt_file = string
    key_file = optional(string)
    ca_file  = optional(string)
  })
  default = null
}

variable "azure" {
  description = <<-EOT
    Azure platform-log shaping (port of the Fluent Bit aggregator Lua): service name, Container Apps console allow
    list, resource-scope tags (lowercase resource id prefix -> tags; subscription / resource group / resource), static
    tags, message size guard, daily quota per category (0 = off) and per-category sampling percentages.
  EOT
  type = object({
    service           = optional(string, "azure")
    aca_console_allow = optional(list(string), [])
    scope_tags        = optional(map(map(string)), {})
    static_tags       = optional(map(string), {})
    max_message_bytes = optional(number, 900000)
    dedupe            = optional(bool, true)
    daily_quota_bytes = optional(number, 0)
    sample_categories = optional(map(number), {})
  })
  default = {}
  validation {
    condition     = alltrue([for p in values(var.azure.sample_categories) : p > 0 && p <= 100])
    error_message = "azure.sample_categories values are percentages (0-100]."
  }
}

variable "redaction" {
  description = "Sensitive data scanner rules (custom regexes; matches replaced by [REDACTED]) on every log. Mirrors the Fluent Bit eh_redact filter."
  type = object({
    enabled        = optional(bool, true)
    extra_patterns = optional(map(string), {})
  })
  default = {}
}

variable "archive" {
  description = "Optional Azure Storage archive destination (connection string from DSV -> DD_OP_DESTINATION_DATADOG_ARCHIVES_AZURE_BLOB_CONNECTION_STRING)."
  type = object({
    enabled        = optional(bool, false)
    container_name = optional(string, "datadog-log-archive")
    blob_prefix    = optional(string, "")
  })
  default = {}
}

variable "buffer" {
  description = "Disk buffer per destination (bytes; worker data dir must be persistent). when_full = block (backpressure to sources) | drop_newest."
  type = object({
    disk_max_bytes = optional(number, 1073741824)
    when_full      = optional(string, "block")
  })
  default = {}
  validation {
    condition     = contains(["block", "drop_newest"], var.buffer.when_full) && var.buffer.disk_max_bytes >= 268435456
    error_message = "buffer.when_full must be block or drop_newest; disk_max_bytes >= 256 MiB."
  }
}

variable "secret_refs" {
  description = "Delinea DSV references for the worker secrets: api_key (required), eventhub_connection_string (Kafka SASL password), archive_connection_string."
  type = object({
    api_key                    = string
    eventhub_connection_string = optional(string)
    archive_connection_string  = optional(string)
  })
  validation {
    condition     = alltrue([for r in compact([var.secret_refs.api_key, var.secret_refs.eventhub_connection_string, var.secret_refs.archive_connection_string]) : can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", r))])
    error_message = "secret_refs must be Delinea DSV references (dsv://<path>#<element>)."
  }
}

variable "eventhub_bootstrap" {
  description = "Event Hubs Kafka endpoint <namespace>.servicebus.windows.net:9093 (when sources.eventhub is set)."
  type        = string
  default     = null
}
