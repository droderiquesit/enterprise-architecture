# Required tag set (ADR-0001 §7). Every taggable lab resource uses module.tags.tags.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

variable "environment" {
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
  type = string
}

variable "layer" {
  type = string
  validation {
    condition     = contains(["bootstrap", "foundation", "platform", "applications", "observability"], var.layer)
    error_message = "layer must be one of bootstrap, foundation, platform, applications, observability."
  }
}

variable "service" {
  type    = string
  default = "platform"
}

variable "version_tag" {
  type    = string
  default = "n/a"
}

variable "domain" {
  type    = string
  default = "shared"
}

variable "tier" {
  type    = string
  default = "infrastructure"
}

variable "extra" {
  type    = map(string)
  default = {}
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
  value = local.tags
}
