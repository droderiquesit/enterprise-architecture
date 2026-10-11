# Common inputs (ADR-0001 §6); naming, tags and artifact metadata via modules/deploy-common.
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
  description = "Build outputs keyed by artifact component id (tools/deploy/artifacts.py tfvars); images must be digest-pinned."
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

module "common" {
  source      = "../modules/deploy-common"
  component   = "deploy-partner-sim"
  workload    = "partner"
  environment = var.environment
  artifacts   = var.artifacts
}

locals {
  component        = "deploy-partner-sim"
  tags             = module.common.tags
  names            = module.common.names
  location         = var.environment.location
  env_name         = var.environment.name
  artifact_version = module.common.artifact_version
  artifact_commit  = module.common.artifact_commit
}
