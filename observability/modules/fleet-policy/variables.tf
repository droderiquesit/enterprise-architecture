variable "policy" {
  description = "Decoded fleet policy (schemas/fleet-policy.v1.schema.json); null = the package default config/fleet-policy.yaml."
  type        = any
  default     = null
}

variable "architecture" {
  description = "Hosting architecture of the workload / resource: aks | aca | aci | appservice | functions | logicapp | vm | vmss | swa | batch. Null = environment-wide settings only."
  type        = string
  default     = null
}

variable "runtime" {
  description = "Workload runtime: dotnet | python | node | java | browser | other. Null for infrastructure."
  type        = string
  default     = null
}

variable "os_type" {
  description = "linux | windows (App Service plans, VMs)."
  type        = string
  default     = "linux"
  validation {
    condition     = contains(["linux", "windows"], var.os_type)
    error_message = "os_type must be linux or windows."
  }
}

variable "env" {
  description = "Environment name (selects environments.<env> overrides)."
  type        = string
  default     = ""
}

variable "overrides" {
  description = "Per-workload overrides, highest precedence (same shape as a policy section: log_pipeline, logs, apm, profiling, agent, rum, op_worker)."
  type        = any
  default     = {}
}
