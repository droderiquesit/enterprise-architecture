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

# Upstream contract: catalog/contracts/foundation-network.v1.schema.json (only the fields used here).
variable "foundation_network" {
  type = object({
    resource_group_name = string
    location            = string
    spoke_vnet_id       = string
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
  })
}

# Upstream contract: catalog/contracts/foundation-identity.v2.schema.json (only the fields used here).
variable "foundation_identity" {
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
    # Delinea DSV references (ADR-0001 section 14): dsv://<base_path>/<name>#value - never values.
    secrets = object({
      base_path = string
      refs      = optional(map(string), {})
    })
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-documentdb)."
  type = object({
    # M10 = smallest paid (burstable) tier; the Free tier does not support Microsoft Entra ID.
    compute_tier             = optional(string, "M10")
    storage_size_in_gb       = optional(number, 32)
    server_version           = optional(string, "8.0")
    private_endpoint_enabled = optional(bool, true)
    admin_secret_name        = optional(string, "documentdb-admin-password")
  })
  default = {}
  validation {
    condition     = var.settings.compute_tier != "Free"
    error_message = "The Free tier does not support Microsoft Entra ID authentication; use M10 or higher."
  }
}

# Secret input from Delinea DSV (pipeline: tools/secrets/fetch.py -> TF_VAR_admin_password). Not ephemeral: the
# argument has no write-only form, so the value is stored in state.
variable "admin_password" {
  description = "Native administrator password (DSV documentdb-admin-password)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_password) >= 8 && length(var.admin_password) <= 256
    error_message = "admin_password must be 8-256 characters (DSV documentdb-admin-password)."
  }
}
