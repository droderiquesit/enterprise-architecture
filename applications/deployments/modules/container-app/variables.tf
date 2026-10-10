variable "name" {
  description = "Container app name (2-32 chars, lowercase alphanumerics and '-')."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.name))
    error_message = "name must be 2-32 lowercase alphanumerics/'-', start with a letter and not end with '-'."
  }
}

variable "resource_group_name" {
  description = "Resource group of the container app."
  type        = string
}

variable "environment_id" {
  description = "Container Apps environment id (platform-containerapps contract)."
  type        = string
}

variable "workload_profile_name" {
  description = "Consumption (default) or a dedicated profile name such as dedicated-d4."
  type        = string
  default     = "Consumption"
}

variable "tags" {
  description = "Azure tags of the container app (required tags + workload azure_tags)."
  type        = map(string)
}

variable "identity" {
  description = "User-assigned identity of the workload (ACR pull; the app and dsv-fetch read Delinea DSV with it)."
  type = object({
    id        = string
    client_id = string
  })
}

variable "registry_server" {
  description = "ACR login server (pull with the user-assigned identity; AcrPull granted by platform-shared)."
  type        = string
}

variable "container" {
  description = "App container: name, digest-pinned image, cpu/memory and optional command/args."
  type = object({
    name    = string
    image   = string
    cpu     = optional(number, 0.5)
    memory  = optional(string, "1Gi")
    command = optional(list(string))
    args    = optional(list(string))
  })
  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.container.image))
    error_message = "container.image must be digest-pinned (<registry>/<repo>@sha256:<64 hex>); tags such as :latest are rejected."
  }
}

variable "env" {
  description = "Environment (app-env output `env`): plain values; secret settings are dsv:// references resolved by the app."
  type        = map(string)
}

variable "sidecar_patch" {
  description = "app-env output `container_app_patch` (serverless-init or Fluent Bit sidecar, dsv-fetch init / refresher containers, volumes, config-file secrets). Null = no sidecar."
  type        = any
  default     = null
}

variable "ingress" {
  description = "HTTP ingress. Null = no ingress (background worker)."
  type = object({
    external     = optional(bool, false)
    target_port  = optional(number, 8080)
    transport    = optional(string, "auto")
    cors_origins = optional(list(string), [])
  })
  default = {}
}

variable "probes" {
  description = "HTTP probe port and paths (startup/liveness on health_path, readiness on ready_path)."
  type = object({
    port         = optional(number, 8080)
    health_path  = optional(string, "/healthz")
    ready_path   = optional(string, "/readyz")
    initial_wait = optional(number, 5)
  })
  default = {}
}

variable "scale" {
  description = "Replica bounds and HTTP concurrency of the scale rule (min_replicas 0 = scale to zero)."
  type = object({
    min_replicas     = optional(number, 0)
    max_replicas     = optional(number, 3)
    http_concurrency = optional(number, 20)
  })
  default = {}
  validation {
    condition     = var.scale.min_replicas >= 0 && var.scale.max_replicas >= 1 && var.scale.max_replicas <= 30 && var.scale.min_replicas <= var.scale.max_replicas
    error_message = "scale: 0 <= min_replicas <= max_replicas <= 30 (lab ceiling)."
  }
}

variable "revisions" {
  description = <<-EOT
    Revision management. mode = Multiple keeps previous revisions active for traffic-based rollback:
    latest_weight < 100 together with previous_revision_suffix splits traffic (canary or rollback);
    latest_weight = 0 sends everything back to previous_revision_suffix.
  EOT
  type = object({
    mode                     = optional(string, "Multiple")
    latest_weight            = optional(number, 100)
    previous_revision_suffix = optional(string)
    max_inactive             = optional(number, 5)
  })
  default = {}
  validation {
    condition     = contains(["Single", "Multiple"], var.revisions.mode) && var.revisions.latest_weight >= 0 && var.revisions.latest_weight <= 100
    error_message = "revisions.mode must be Single or Multiple and latest_weight 0-100."
  }
  validation {
    condition     = var.revisions.latest_weight == 100 || (var.revisions.mode == "Multiple" && var.revisions.previous_revision_suffix != null)
    error_message = "Splitting traffic requires mode = Multiple and previous_revision_suffix."
  }
}
