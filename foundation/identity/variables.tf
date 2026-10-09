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

variable "foundation_network" {
  description = "foundation-network contract v1 (only the fields used here)."
  type = object({
    subnets = map(object({
      id = string
    }))
    private_dns_zones = map(object({
      id = string
    }))
  })
}

variable "settings" {
  description = "Component settings (components.foundation-identity). See README."
  type = object({
    key_vault_sku = optional(string, "standard")
    # Purge protection cannot be disabled once enabled and blocks re-creating a vault with the same name for
    # soft_delete_retention_days after deletion (lab teardown implication, see README).
    purge_protection_enabled   = optional(bool, true)
    soft_delete_retention_days = optional(number, 7)
    # Optional operator IPs allowed through the vault firewall while public network access stays disabled
    # (only effective if public_network_access_enabled = true; kept for break-glass).
    public_network_access_enabled = optional(bool, false)
    allowed_ip_ranges             = optional(list(string), [])

    # Extra workload identities beyond the catalogue in identities.tf (key => purpose).
    extra_identities = optional(map(string), {})
    # Engines whose DBM agent must use SQL authentication (no Entra managed-identity support in the Datadog check).
    # Each adds a dbm-<engine>-password secret ID and grants obs-dbm read access.
    dbm_sql_auth_engines = optional(list(string), ["mysql", "sqlvm"])

    # false: Key Vault Secrets User at vault scope (works before secrets exist). true: one assignment per
    # identity x secret at secret scope (least privilege; requires every secret to exist first).
    secret_scoped_assignments = optional(bool, false)

    # Principals (object IDs) that may set/rotate secret values (Key Vault Secrets Officer), e.g. the operator group.
    secret_officer_principal_ids = optional(list(string), [])
    # Pipeline principals that read pipeline-only secrets (datadog-app-key, datadog-api-key), e.g. bootstrap apply identity.
    pipeline_reader_principal_ids = optional(list(string), [])
    # Bootstrap `packages` container (resource id from the bootstrap contract). Workload identities that install
    # zip packages by managed identity (VM run commands, Windows Consumption, Batch) get Storage Blob Data Reader on it.
    packages_container_id     = optional(string)
    package_reader_identities = optional(list(string), ["hello-worker", "hello-inventory-api", "hello-dbadapter", "hello-durable", "hello-functions", "hello-jobs"])
  })
  default = {}

  validation {
    condition     = var.settings.soft_delete_retention_days >= 7 && var.settings.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be 7..90."
  }
  validation {
    condition     = contains(["standard", "premium"], var.settings.key_vault_sku)
    error_message = "key_vault_sku must be standard or premium."
  }
  validation {
    condition     = alltrue([for e in var.settings.dbm_sql_auth_engines : contains(["mysql", "sqlvm", "sqldb", "sqlmi", "postgres"], e)])
    error_message = "dbm_sql_auth_engines entries must be one of mysql, sqlvm, sqldb, sqlmi, postgres."
  }
}
