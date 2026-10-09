variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "service_plan" {
  description = "App Service plan from the platform-appservice contract."
  type = object({
    id  = string
    sku = string
  })
}

variable "os_type" {
  type = string
  validation {
    condition     = contains(["Linux", "Windows"], var.os_type)
    error_message = "os_type must be Linux or Windows."
  }
}

variable "mode" {
  description = "code (zip deployed by scripts/deploy-zip.sh) | container (digest-pinned image pulled with the identity)."
  type        = string
  validation {
    condition     = contains(["code", "container"], var.mode)
    error_message = "mode must be code or container."
  }
}

variable "stack" {
  description = "Code stack: dotnet_version (Windows: v10.0, Linux: 10.0) or python_version (Linux)."
  type = object({
    dotnet_version = optional(string)
    python_version = optional(string)
  })
  default = {}
}

variable "image" {
  description = "Container mode: <registry>/<repo>@sha256:<digest>."
  type        = string
  default     = null
  validation {
    condition     = var.image == null || can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", coalesce(var.image, "x")))
    error_message = "image must be digest-pinned."
  }
}

variable "identity" {
  type = object({
    id        = string
    client_id = string
  })
}

variable "app_settings" {
  description = "App settings: plain values; secret settings carry dsv:// references the app resolves at start-up with its managed identity (no Key Vault references)."
  type        = map(string)
  validation {
    condition     = alltrue([for k, v in var.app_settings : !can(regex("(?i)(password|pwd|accountkey|sharedaccesskey)\\s*=", v))])
    error_message = "app_settings must not contain inline passwords or keys; use dsv:// references (Delinea DSV)."
  }
  validation {
    condition     = !anytrue([for k, v in var.app_settings : can(regex("^@Microsoft[.]Key[V]ault[(]", v))])
    error_message = "Key Vault references are not used (ADR-0001 section 14): the value of a secret setting is its dsv:// reference."
  }
}

variable "startup_command" {
  type    = string
  default = null
}

variable "integration_subnet_id" {
  type    = string
  default = null
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}

variable "private_endpoint" {
  description = "Private endpoint (sites) in the private-endpoints subnet; null = public endpoint restricted by allowed_ip_ranges."
  type = object({
    subnet_id   = string
    dns_zone_id = optional(string)
  })
  default = null
}

variable "allowed_ip_ranges" {
  type    = list(string)
  default = []
}

variable "staging_slot" {
  description = "Create a `staging` slot when the plan SKU supports slots (Standard/Premium/Isolated)."
  type        = bool
  default     = true
}

variable "always_on" {
  type    = bool
  default = true
}
