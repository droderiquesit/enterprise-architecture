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

# Global `secrets` section of environments/<env>/environment.yaml (rendered because this root declares it).
# Identifiers only: the DSV tenant name is not a secret.
variable "secrets" {
  description = "Delinea DSV settings: provider (delinea-dsv), tenant, tld (default com), auth_provider (DSV Azure auth provider name), optional base_url."
  type = object({
    provider      = optional(string, "delinea-dsv")
    tenant        = string
    tld           = optional(string, "com")
    auth_provider = string
    base_url      = optional(string)
  })

  validation {
    condition     = var.secrets.provider == "delinea-dsv"
    error_message = "secrets.provider must be delinea-dsv (ADR-0001 section 14: all secrets live in Delinea DSV)."
  }
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.secrets.tenant))
    error_message = "secrets.tenant must be the DSV tenant name (lowercase letters, digits, dashes)."
  }
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.secrets.auth_provider))
    error_message = "secrets.auth_provider must be the name of the DSV Azure auth provider (bootstrap/README.md)."
  }
  validation {
    condition     = contains(["com", "eu", "com.au", "ca"], var.secrets.tld)
    error_message = "secrets.tld must be a DSV region TLD: com, eu, com.au or ca (dsv-cli constants/request.go)."
  }
}

variable "settings" {
  description = "Component settings (components.foundation-identity). See README."
  type = object({
    # Extra workload identities beyond the catalogue in main.tf (key => purpose).
    extra_identities = optional(map(string), {})
    # Extra DSV secret names per identity (catalogue or extra identities); each name must be in secrets.yaml.
    extra_identity_secrets = optional(map(list(string)), {})
    # Engines whose DBM agent must use SQL authentication (no Entra managed-identity support in the Datadog check).
    # Each adds a dbm-<engine>-password reference and grants obs-dbm read access.
    dbm_sql_auth_engines = optional(list(string), ["mysql", "sqlvm"])

    # Bootstrap `packages` container (resource id from the bootstrap contract). Workload identities that install
    # zip packages by managed identity (VM run commands, Windows Consumption, Batch) get Storage Blob Data Reader on it.
    packages_container_id     = optional(string)
    package_reader_identities = optional(list(string), ["hello-worker", "hello-inventory-api", "hello-dbadapter", "hello-durable", "hello-functions", "hello-jobs"])
  })
  default = {}

  validation {
    condition     = alltrue([for e in var.settings.dbm_sql_auth_engines : contains(["mysql", "sqlvm", "sqldb", "sqlmi", "postgres"], e)])
    error_message = "dbm_sql_auth_engines entries must be one of mysql, sqlvm, sqldb, sqlmi, postgres."
  }
}
