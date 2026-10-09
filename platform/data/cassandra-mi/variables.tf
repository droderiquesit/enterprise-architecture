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
  description = "Component settings (environments/<env>/environment.yaml components.platform-db-cassandra-mi)."
  type = object({
    # Disabled by default: 3 x Standard_D8s_v4 nodes + P30 disks cost roughly USD 1,500+/month.
    enabled           = optional(bool, false)
    cassandra_version = optional(string, "5.0")
    node_count        = optional(number, 3)
    sku_name          = optional(string, "Standard_D8s_v4")
    disk_count        = optional(number, 1)
    # Object ID of the "Azure Cosmos DB" first-party service principal in this tenant
    # (az ad sp show --id a232010e-820c-4083-83bb-3ace5fc29d0b --query id -o tsv). It needs
    # Network Contributor (subnets/join/action) on the delegated subnet before the cluster is created.
    cosmosdb_service_principal_object_id = optional(string)
    # "subnet" (least privilege) or "vnet" (as in Microsoft's quickstart).
    network_contributor_scope = optional(string, "subnet")
    admin_secret_name         = optional(string, "cassandra-mi-admin-password")
  })
  default = {}

  validation {
    condition     = !var.settings.enabled || var.settings.cosmosdb_service_principal_object_id != null
    error_message = "cosmosdb_service_principal_object_id is required when Cassandra MI is enabled."
  }
  validation {
    condition     = var.settings.node_count >= 3
    error_message = "Use at least 3 nodes per datacenter."
  }
  validation {
    condition     = contains(["subnet", "vnet"], var.settings.network_contributor_scope)
    error_message = "network_contributor_scope must be subnet or vnet."
  }
}

# Secret input from Delinea DSV (pipeline: tools/secrets/fetch.py -> TF_VAR_admin_password); only needed when enabled.
variable "admin_password" {
  description = "Default admin password of the cluster (DSV cassandra-mi-admin-password). Stored in state (no write-only form)."
  type        = string
  default     = null
  sensitive   = true
}
