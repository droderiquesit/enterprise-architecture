# Naming, required tags (ADR-0001 §7) and artifact metadata shared by every deployment root.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

variable "environment" {
  description = "The calling root's var.environment (ADR-0001 §6)."
  type        = any
}

variable "artifacts" {
  description = "The calling root's var.artifacts (validated there)."
  type        = any
}

variable "component" {
  description = "Registry component id, e.g. deploy-appservice."
  type        = string
}

variable "workload" {
  description = "Naming workload segment."
  type        = string
}

module "naming" {
  source          = "../../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = var.workload
}

module "tags" {
  source      = "../../../../foundation/modules/tags"
  component   = var.component
  layer       = "applications"
  domain      = "applications"
  tier        = "application"
  environment = var.environment
}

output "names" {
  value = module.naming.names
}

output "suffix" {
  value = module.naming.suffix
}

output "tags" {
  value = module.tags.tags
}

# version = explicit version, else the immutable build tag, else the digest / package hash prefix.
output "artifact_version" {
  value = {
    for k, a in var.artifacts : k => replace(coalesce(a.version, a.tag, try(substr(split("@sha256:", coalesce(a.image, ""))[1], 0, 12), null), try(substr(a.package_sha256, 0, 12), null), "unknown"), "/[,= ]/", "-")
  }
}

output "artifact_commit" {
  value = { for k, a in var.artifacts : k => coalesce(a.commit, "unknown") }
}
