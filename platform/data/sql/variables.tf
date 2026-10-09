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

# Upstream contract: catalog/contracts/foundation-identity.v1.schema.json (only the fields used here).
variable "foundation_identity" {
  type = object({
    key_vault_id  = string
    key_vault_uri = string
    secret_ids    = optional(map(string), {}) # versionless Key Vault secret IDs (values set out-of-band)
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-sql)."
  type = object({
    # Microsoft Entra administrator of the logical server (a group is recommended; the pipeline
    # apply identity must be a member so it can run scripts/grant-db-users.sql).
    entra_admin = object({
      login     = string
      object_id = string
    })
    private_endpoint_enabled  = optional(bool, true)
    minimum_tls_version       = optional(string, "1.2")
    pitr_retention_days       = optional(number, 7)
    backup_storage_redundancy = optional(string, "Local")

    # db orders: provisioned DTU (cheapest sensible: S0, 10 DTU). Owner hello-orders-api.
    orders = optional(object({
      sku_name    = optional(string, "S0")
      max_size_gb = optional(number, 2)
    }), {})

    # db fulfillment: General Purpose serverless with auto-pause. Owner hello-durable (+ hello-jobs).
    fulfillment = optional(object({
      sku_name                    = optional(string, "GP_S_Gen5_1")
      min_capacity                = optional(number, 0.5)
      auto_pause_delay_in_minutes = optional(number, 60)
      max_size_gb                 = optional(number, 5)
    }), {})

    # db adapter: provisioned Basic for hello-dbadapter-sql.
    adapter = optional(object({
      sku_name    = optional(string, "Basic")
      max_size_gb = optional(number, 2)
    }), {})

    # Optional elastic pool + db adapter_pool (catalog: sql-elastic-pool, default disabled).
    elastic_pool = optional(object({
      enabled         = optional(bool, false)
      sku_name        = optional(string, "BasicPool")
      tier            = optional(string, "Basic")
      capacity        = optional(number, 50)
      max_size_gb     = optional(number, 4.8828125)
      db_min_capacity = optional(number, 0)
      db_max_capacity = optional(number, 5)
    }), {})

    # Optional Hyperscale serverless db adapter_hs (catalog: sql-hyperscale, default disabled).
    # Hyperscale serverless auto-pause is a preview feature: -1 (disabled) by default.
    hyperscale = optional(object({
      enabled                     = optional(bool, false)
      sku_name                    = optional(string, "HS_S_Gen5_2")
      min_capacity                = optional(number, 0.5)
      auto_pause_delay_in_minutes = optional(number, -1)
    }), {})
  })

  validation {
    condition     = var.settings.pitr_retention_days >= 1 && var.settings.pitr_retention_days <= 35
    error_message = "pitr_retention_days must be 1-35."
  }
  validation {
    condition     = contains(["1.2"], var.settings.minimum_tls_version)
    error_message = "minimum_tls_version must be 1.2 (lab baseline)."
  }
  validation {
    condition     = startswith(var.settings.fulfillment.sku_name, "GP_S_")
    error_message = "fulfillment must use a General Purpose serverless SKU (GP_S_*)."
  }
}
