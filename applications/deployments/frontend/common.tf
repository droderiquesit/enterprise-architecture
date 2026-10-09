# Generated common inputs (environment, artifacts), naming and required tags (ADR-0001 §6, §7).
variable "environment" {
  description = "Environment globals rendered by tools/config/render.py (ADR-0001 §6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "artifacts" {
  description = <<-EOT
    Immutable build outputs keyed by artifact component id (svc-bff, ...), written by
    `tools/deploy/artifacts.py tfvars` into artifacts.auto.tfvars.json. Images are ALWAYS digest-pinned
    (<registry>/<repo>@sha256:<digest>); tags such as :latest are rejected.
  EOT
  type = map(object({
    name           = optional(string)
    image          = optional(string)
    digest         = optional(string)
    package_url    = optional(string)
    package_sha256 = optional(string)
    version        = optional(string)
    commit         = optional(string)
    source_fp      = optional(string)
    tag            = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([for a in values(var.artifacts) : a.image == null || can(regex(
      "^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", coalesce(a.image, "x")
    ))])
    error_message = "artifacts[*].image must be digest-pinned (<registry>/<repo>@sha256:<64 hex>); mutable tags are not allowed."
  }
  validation {
    condition     = alltrue([for a in values(var.artifacts) : a.package_url == null || (startswith(coalesce(a.package_url, "x"), "https://") && can(regex("^[a-f0-9]{64}$", coalesce(a.package_sha256, "x"))))])
    error_message = "artifacts[*].package_url must be https and come with its package_sha256 (64 hex)."
  }
}

module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "frontend"
}

module "tags" {
  source    = "../../../foundation/modules/tags"
  component = "deploy-frontend"
  layer     = "applications"
  domain    = "applications"
  tier      = "application"
  environment = {
    name        = var.environment.name
    location    = var.environment.location
    owner       = var.environment.owner
    team        = var.environment.team
    cost_center = var.environment.cost_center
    expires_on  = var.environment.expires_on
    tags        = var.environment.tags
  }
}

locals {
  component = "deploy-frontend"
  tags      = module.tags.tags
  names     = module.naming.names
  location  = var.environment.location
  env_name  = var.environment.name
  prefix    = var.environment.name_prefix

  # Artifact metadata: version = explicit version, else the immutable build tag, else the digest prefix.
  artifact_version = {
    for k, a in var.artifacts : k => replace(coalesce(a.version, a.tag, try(substr(split("@sha256:", coalesce(a.image, ""))[1], 0, 12), null), try(substr(a.package_sha256, 0, 12), null), "unknown"), "/[,= ]/", "-")
  }
  artifact_commit = { for k, a in var.artifacts : k => coalesce(a.commit, "unknown") }
}
