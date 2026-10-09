variable "role" {
  description = "sidecar | sidecar-forward | aggregator | aggregator-forward | k8s-daemonset | linux-host | windows-host"
  type        = string
  validation {
    condition     = contains(["sidecar", "sidecar-forward", "aggregator", "aggregator-forward", "k8s-daemonset", "linux-host", "windows-host"], var.role)
    error_message = "role must be one of sidecar, sidecar-forward, aggregator, aggregator-forward, k8s-daemonset, linux-host, windows-host."
  }
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "static_tags" {
  description = "Tags added to every record (FLB_DD_TAGS), e.g. { env = \"dev\", team = \"platform\" }."
  type        = map(string)
  default     = {}
}

variable "dd_source" {
  description = "Default ddsource (FLB_DD_SOURCE)."
  type        = string
  default     = null
}

variable "dd_service" {
  description = "Fallback service for lines without one (FLB_DD_SERVICE)."
  type        = string
  default     = null
}

variable "log_paths" {
  description = "Host roles: files/globs to tail (FLB_LOG_PATHS)."
  type        = list(string)
  default     = []
}

variable "state_dir" {
  description = "Writable state/buffer dir (FLB_STATE_DIR). Null = role default."
  type        = string
  default     = null
}

variable "exclude_namespaces" {
  description = "k8s-daemonset: namespaces whose container logs are NOT collected."
  type        = list(string)
  default     = ["kube-system", "datadog", "fluent-bit", "gatekeeper-system", "calico-system", "tigera-operator"]
}

variable "throttle_rate" {
  description = "k8s-daemonset: records per second per node before throttling."
  type        = number
  default     = 2000
}

variable "systemd_unit" {
  description = "linux-host: optional journald unit to collect (installs linux-host-systemd.yaml as inputs-extra.yaml)."
  type        = string
  default     = null
}

variable "windows_event_log" {
  description = "windows-host: also collect Application/System event logs (winevtlog)."
  type        = bool
  default     = false
}

variable "tls" {
  description = "Datadog output TLS. Only local tests against a mock intake turn this off."
  type        = bool
  default     = true
  validation {
    condition     = var.tls
    error_message = "TLS to the Datadog intake cannot be disabled in deployed configurations."
  }
}

variable "canary_interval_seconds" {
  description = "Interval of the pipeline canary record (service telemetry-canary, canary:true) for aggregator/daemonset/host roles."
  type        = number
  default     = 60
  validation {
    condition     = var.canary_interval_seconds >= 10 && var.canary_interval_seconds <= 3600
    error_message = "canary_interval_seconds must be 10-3600."
  }
}
