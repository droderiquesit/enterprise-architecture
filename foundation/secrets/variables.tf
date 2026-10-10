variable "environment" {
  description = "Environment globals (ADR-0001 §6)."
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

variable "foundation_identity" {
  description = "foundation-identity contract v2 (catalog/contracts/foundation-identity.v2.schema.json), only the fields used here: identities (resource id, name, secret names) and the DSV settings."
  type = object({
    identities = map(object({
      id      = string
      name    = string
      secrets = list(string)
    }))
    secrets = object({
      base_url      = string
      base_path     = string
      auth_provider = string
      refs          = map(string)
    })
  })
}

variable "settings" {
  description = "Component settings (components.foundation-secrets). See README."
  type = object({
    # Identity that writes Azure-generated values (tools/secrets/publish.py) - the deploy agent runs publish.py
    # in the publisher component's apply job, so it gets create/update on exactly the generated paths.
    publisher_identity = optional(string, "deploy-agent")
    # Identity that runs tools/secrets/check.py (metadata-only `list` on the environment's paths).
    checker_identity = optional(string, "deploy-agent")
    # Identities that get no DSV user even if they list secrets (break-glass switch; default none).
    excluded_identities = optional(list(string), [])
    # Marker written into every managed object (user displayName, permission description). dsv_apply only
    # changes objects that carry it and never deletes anything.
    marker = optional(string, "managed-by:foundation-secrets")
  })
  default = {}

  validation {
    condition     = can(regex("^[a-z0-9:-]{8,40}$", var.settings.marker))
    error_message = "marker must be 8-40 characters of [a-z0-9:-]."
  }
}
