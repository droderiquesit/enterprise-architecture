variable "distribution" {
  description = "upstream (otel/opentelemetry-collector-contrib + datadog exporter; default, GA) or ddot (Datadog Distribution of OTel Collector, standalone)."
  type        = string
  default     = "upstream"
  validation {
    condition     = contains(["upstream", "ddot"], var.distribution)
    error_message = "distribution must be upstream or ddot."
  }
}

variable "sampling" {
  description = "probabilistic | tail | none"
  type        = string
  default     = "probabilistic"
  validation {
    condition     = contains(["probabilistic", "tail", "none"], var.sampling)
    error_message = "sampling must be probabilistic, tail or none."
  }
}

variable "sampling_percentage" {
  type    = number
  default = 100
  validation {
    condition     = var.sampling_percentage >= 0 && var.sampling_percentage <= 100
    error_message = "sampling_percentage must be 0-100."
  }
}

variable "bearer_auth" {
  description = "Require a bearer token on OTLP (upstream only; token read from the file /dsv-secrets/otlp-bearer-token written by dsv-fetch)."
  type        = bool
  default     = false
}

variable "fluentbit_metrics_target" {
  description = "host:port of a Fluent Bit aggregator whose Prometheus self-metrics the gateway scrapes. Null = none."
  type        = string
  default     = null
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "env" {
  description = "Default deployment environment for clients that send none (DD_ENV)."
  type        = string
}

variable "memory_mib" {
  description = "Container memory (MiB); memory_limiter gets 80% / spike 20%."
  type        = number
  default     = 1024
}

variable "hostname" {
  description = "DD_HOSTNAME (DDOT requires one; also keeps gateway replicas from being reported as separate hosts)."
  type        = string
  default     = "otel-gateway"
}

variable "images" {
  type = object({
    upstream = optional(string, "otel/opentelemetry-collector-contrib:0.162.0")
    ddot     = optional(string, "datadog/ddot-collector:7.84.2")
  })
  default = {}
}

variable "otlp_logs" {
  description = <<-EOT
    What the gateway does with OTLP LOGS (e.g. Azure Functions host/worker logs exported because
    OTEL_EXPORTER_OTLP_ENDPOINT is set): drop (default - accepted and discarded, app logs arrive via Fluent Bit)
    or forward (opt-in, only for sources without a Fluent Bit route; otherwise duplicates).
  EOT
  type        = string
  default     = "drop"
  validation {
    condition     = contains(["drop", "forward"], var.otlp_logs)
    error_message = "otlp_logs must be drop or forward."
  }
}

variable "default_attributes" {
  description = "Environment-wide policy tags as OTel resource attributes (modules/tagging otel_resource_attributes of the environment identity, e.g. deployment.environment.name, region, managed_by, application + static tags), inserted when a client sent none."
  type        = map(string)
  default     = {}
}

variable "service_attributes" {
  description = "Per service.name: the service's policy attributes (team, owner, domain, tier, ...) inserted when the client sent none - the gateway enforces the onboarding manifests on telemetry of managed runtimes."
  type        = map(map(string))
  default     = {}
}

variable "metric_attribute_keys" {
  description = "Resource attributes copied onto metric data points (Datadog metric tags) when the point has none, e.g. the non-unified policy keys (team, owner, domain, tier, application, region)."
  type        = list(string)
  default     = []
}
