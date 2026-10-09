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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-postgresql)."
  type = object({
    # Microsoft Entra administrator (a group is recommended; the pipeline apply identity and the
    # obs-dbm setup step run as a member of it).
    entra_admin = object({
      object_id      = string
      principal_name = string
      principal_type = optional(string, "Group")
    })
    # vnet = VNet injection into subnet `postgres` (delegated) + private DNS zone;
    # private-endpoint = public access disabled + PE in `private-endpoints`.
    network_mode          = optional(string, "vnet")
    version               = optional(string, "18")
    sku_name              = optional(string, "B_Standard_B1ms")
    storage_mb            = optional(number, 32768)
    storage_tier          = optional(string, "P4")
    backup_retention_days = optional(number, 7)
    extra_extensions      = optional(list(string), [])

    # Optional Elastic Cluster (catalog: postgresql-elastic-cluster) for hello-dbadapter-postgresql-elastic.
    elastic_cluster = optional(object({
      enabled    = optional(bool, false)
      node_count = optional(number, 2)
      sku_name   = optional(string, "GP_Standard_D2ds_v5")
      storage_mb = optional(number, 32768)
      # Private Link group ID; flexible-server value assumed for elastic clusters (verify at enable time:
      # az network private-link-resource list --id <cluster id>).
      pe_group_id = optional(string, "postgresqlServer")
    }), {})
  })

  validation {
    condition     = contains(["vnet", "private-endpoint"], var.settings.network_mode)
    error_message = "network_mode must be vnet or private-endpoint."
  }
  validation {
    condition     = var.settings.backup_retention_days >= 7 && var.settings.backup_retention_days <= 35
    error_message = "backup_retention_days must be 7-35."
  }
  validation {
    condition     = !var.settings.elastic_cluster.enabled || !startswith(var.settings.elastic_cluster.sku_name, "B_")
    error_message = "Elastic clusters require a General Purpose or Memory Optimized SKU."
  }
}
