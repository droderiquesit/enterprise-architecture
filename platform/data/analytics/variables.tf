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
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-data-analytics)."
  type = object({
    private_endpoints_enabled = optional(bool, true)

    blob = optional(object({
      enabled          = optional(bool, true)
      replication_type = optional(string, "LRS")
    }), {})

    adls = optional(object({
      enabled          = optional(bool, true)
      replication_type = optional(string, "LRS")
    }), {})

    # Azure Data Explorer Dev/Test (no SLA, single node) with auto-stop after 5 idle days.
    data_explorer = optional(object({
      enabled            = optional(bool, false)
      sku_name           = optional(string, "Dev(No SLA)_Standard_E2a_v4")
      capacity           = optional(number, 1)
      auto_stop_enabled  = optional(bool, true)
      hot_cache_period   = optional(string, "P1D")
      soft_delete_period = optional(string, "P7D")
    }), {})

    # Azure AI Search. `free` has no private endpoint support, so `basic` is the private default.
    search = optional(object({
      enabled         = optional(bool, false)
      sku             = optional(string, "basic")
      replica_count   = optional(number, 1)
      partition_count = optional(number, 1)
    }), {})

    # Synapse workspace (catalog: synapse-sql / synapse-spark are cataloged-only; disabled by default).
    synapse = optional(object({
      enabled     = optional(bool, false)
      entra_admin = optional(object({ login = string, object_id = string }))
    }), {})
  })
  default = {}

  validation {
    condition     = !var.settings.synapse.enabled || (var.settings.adls.enabled && var.settings.synapse.entra_admin != null)
    error_message = "Synapse requires adls.enabled = true and synapse.entra_admin."
  }
  validation {
    condition     = !(var.settings.search.enabled && var.settings.search.sku == "free" && var.settings.private_endpoints_enabled)
    error_message = "The free AI Search tier does not support private endpoints; use basic or disable private endpoints (README exception)."
  }
}
