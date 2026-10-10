# Required tag set (ADR-0001 §7). Every taggable lab resource uses module.tags.tags.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

variable "environment" {
  description = "Environment globals (subset of ADR-0001 section 6 var.environment); extra attributes are ignored."
  type = object({
    name        = string
    location    = string
    owner       = string
    team        = string
    cost_center = string
    expires_on  = string
    tags        = map(string)
  })
}

variable "component" {
  description = "Registry component id (catalog/components.yaml), e.g. \"foundation-network\"."
  type        = string
}

variable "layer" {
  description = "Owning layer: bootstrap, foundation, platform, applications or observability."
  type        = string
  validation {
    condition     = contains(["bootstrap", "foundation", "platform", "applications", "observability"], var.layer)
    error_message = "layer must be one of bootstrap, foundation, platform, applications, observability."
  }
}

variable "service" {
  description = "Datadog service tag; \"platform\" for infrastructure."
  type        = string
  default     = "platform"
}

variable "version_tag" {
  description = "Datadog version tag; \"n/a\" for infrastructure."
  type        = string
  default     = "n/a"
}

variable "domain" {
  description = "Business/technical domain tag, e.g. network, identity, data."
  type        = string
  default     = "shared"
}

variable "tier" {
  description = "Tier tag, e.g. infrastructure, frontend, backend, data."
  type        = string
  default     = "infrastructure"
}

variable "extra" {
  description = "Additional tags merged last (override the required set)."
  type        = map(string)
  default     = {}
}

locals {
  tags = merge(var.environment.tags, {
    env                 = var.environment.name
    application         = "enterprise-hello"
    service             = var.service
    version             = var.version_tag
    team                = var.environment.team
    owner               = var.environment.owner
    domain              = var.domain
    tier                = var.tier
    region              = var.environment.location
    managed_by          = "terraform"
    component           = var.component
    layer               = var.layer
    cost_center         = var.environment.cost_center
    expires_on          = var.environment.expires_on
    data_classification = "synthetic"
    repository          = "azure-enterprise-observability-lab"
  }, var.extra)
}

output "tags" {
  description = "Required ADR-0001 section 7 tag set merged with environment.tags and extra."
  value       = local.tags
}
