variable "policy" {
  description = <<-EOT
    Decoded tag policy (schemas/tag-policy.v1.schema.json), e.g. yamldecode(file("my-tag-policy.yaml")).
    null = the package default config/tag-policy.yaml. Pass the SAME policy to every module of a root.
  EOT
  type        = any
  default     = null
}

variable "identity" {
  description = <<-EOT
    Raw values per CANONICAL policy key (env, service, version, team, owner, application, domain, tier, region,
    managed_by, cost_center, component, or any key your policy adds). Missing / null / empty values fall back to the
    key's policy `default`; still-missing required keys are reported in `missing_required` (and fail the plan when
    the policy enforces them).
  EOT
  type        = map(string)
  default     = {}
}

variable "extra_tags" {
  description = "Additional Datadog tags (key -> value) for this signal source, merged over the policy static tags. Canonical policy keys always win."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.extra_tags) : can(regex("^[a-z][a-z0-9_./-]{0,99}$", k))])
    error_message = "extra_tags keys must be Datadog tag keys: lowercase, starting with a letter ([a-z0-9_./-])."
  }
}

variable "enforce_required" {
  description = "Override the policy's enforce_required (null = use the policy)."
  type        = bool
  default     = null
}
