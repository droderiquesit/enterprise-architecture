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
  description = "foundation-identity contract v2 (catalog/contracts/foundation-identity.v2.schema.json), only the fields used here."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-ledger)."
  type = object({
    # Ledger Administrator (Entra object ID of a group or the pipeline identity).
    administrator_object_id = string
    ledger_type             = optional(string, "Private")
  })
  validation {
    condition     = contains(["Private", "Public"], var.settings.ledger_type)
    error_message = "ledger_type must be Private or Public."
  }
}
