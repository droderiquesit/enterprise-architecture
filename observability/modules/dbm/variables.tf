variable "databases" {
  description = <<-EOT
    Database endpoints to monitor with Datadog Database Monitoring (keyed by a stable name).
      engine          : postgres | mysql | sqlserver   (DBM-supported engines only)
      deployment_type : postgres/mysql -> flexible_server ; sqlserver -> sql_database | managed_instance | virtual_machine
      auth            : password (password_ref required) | managed_identity (postgres + sqlserver only)
      password_ref    : the password as a Delinea DSV reference - NEVER a literal, one secret path everywhere:
                          {kind = "dsv", name = "dsv://<path>#<element>"} -> ENC[dsv://...], resolved by the Agent's
                          secret_backend_command = dsv-fetch agent-backend (ACI Agent, cluster-checks runners, host Agent)
  EOT
  type = map(object({
    engine                     = string
    deployment_type            = string
    host                       = string
    port                       = optional(number)
    database                   = optional(string)
    username                   = optional(string, "datadog")
    auth                       = optional(string, "password")
    managed_identity_client_id = optional(string)
    password_ref = optional(object({
      kind = string
      name = string
    }))
    resource_id = optional(string)
    # application service that owns the database (DBM <-> APM correlation, tag policy `service`)
    service = optional(string)
    tags    = optional(map(string), {})
  }))
  validation {
    condition     = alltrue([for d in values(var.databases) : contains(["postgres", "mysql", "sqlserver"], d.engine)])
    error_message = "Database Monitoring supports engine = postgres, mysql or sqlserver only (Cosmos DB, MariaDB, Redis, Cassandra ... are covered by integrations/APM, not DBM)."
  }
  validation {
    condition = alltrue([for d in values(var.databases) : (
      d.engine == "sqlserver" ? contains(["sql_database", "managed_instance", "virtual_machine"], d.deployment_type) : d.deployment_type == "flexible_server"
    )])
    error_message = "deployment_type: flexible_server for postgres/mysql; sql_database | managed_instance | virtual_machine for sqlserver."
  }
  validation {
    condition     = alltrue([for d in values(var.databases) : contains(["password", "managed_identity"], d.auth) && !(d.engine == "mysql" && d.auth == "managed_identity")])
    error_message = "auth must be password or managed_identity; MySQL DBM does not support Entra managed identity authentication."
  }
  validation {
    condition     = alltrue([for d in values(var.databases) : d.auth == "managed_identity" ? d.managed_identity_client_id != null : (d.password_ref != null && try(d.password_ref.kind, "") == "dsv")])
    error_message = "auth = password needs password_ref {kind = \"dsv\", name = \"dsv://...\"} (Delinea DSV is the only secret source); auth = managed_identity needs managed_identity_client_id."
  }
  validation {
    condition     = alltrue([for d in values(var.databases) : try(d.password_ref.kind, "") != "dsv" || can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", d.password_ref.name))])
    error_message = "password_ref.kind = dsv needs name = dsv://<path>#<element>."
  }
  validation {
    condition     = alltrue([for d in values(var.databases) : d.engine != "sqlserver" || d.deployment_type != "sql_database" || d.database != null])
    error_message = "Azure SQL Database requires database (one DBM instance per database)."
  }
}

variable "hosting" {
  description = <<-EOT
    Where the DBM checks run (always from inside the VNet):
      cluster_checks : whenever a Kubernetes cluster with the Datadog Cluster Agent exists - cluster_check_confd feeds
                       modules/kubernetes (cluster_checks input); the Cluster Agent dispatches the checks to the
                       cluster-checks runners, whose dsv-fetch secret backend resolves the ENC[dsv://...] passwords and
                       whose workload identity logs in to Entra-enabled databases
      aci            : only when there is no cluster - a Datadog Agent container group in the observability subnet
                       (created by this module)
      none           : only render configs (e.g. drop confd into an existing host Agent's conf.d)
  EOT
  type        = string
  default     = "cluster_checks"
  validation {
    condition     = contains(["aci", "cluster_checks", "none"], var.hosting)
    error_message = "hosting must be cluster_checks, aci or none."
  }
}

variable "aci" {
  description = "ACI hosting (hosting = aci): existing subnet (delegated to Microsoft.ContainerInstance/containerGroups), RG, user-assigned identity mapped to a DSV user with read on the API key / DB password paths, DSV endpoint, the digest-pinned dsv-fetch image (registry artifact img-dsv-fetch >= 2.0.0, static binary at /opt/dsv-fetch/dsv-fetch). image: null = the fleet policy <agent.image>:<agent.version>."
  type = object({
    name                = string
    resource_group_name = string
    location            = string
    subnet_id           = string
    identity_id         = string
    identity_client_id  = string
    api_key_ref         = string
    fetch_image         = string
    dsv = object({
      tenant   = optional(string)
      tld      = optional(string, "com")
      base_url = optional(string)
    })
    image     = optional(string)
    cpu       = optional(number, 1)
    memory_gb = optional(number, 2)
  })
  default = null
  validation {
    condition     = var.aci == null || can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.aci.fetch_image))
    error_message = "aci.fetch_image must be the digest-pinned dsv-fetch image (<registry>/<repo>@sha256:<64 hex>)."
  }
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default): the ACI Agent image is <agent.image>:<agent.version> (single pin)."
  type        = any
  default     = null
}

variable "datadog" {
  description = "Datadog site and environment name (env tag) of the checks."
  type = object({
    site = string
    env  = string
  })
}

variable "tags" {
  description = "Azure tags of the resources this module creates (ACI container group)."
  type        = map(string)
  default     = {}
}

variable "sqlserver_driver" {
  description = "ODBC driver name the SQL Server check uses (installed in the Datadog Agent image)."
  type        = string
  default     = "ODBC Driver 18 for SQL Server"
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default) for the DBM instance tags."
  type        = any
  default     = null
}

variable "identity" {
  description = "Canonical tag values shared by the databases (team, owner, region, application, domain, tier, ...). env = datadog.env; service per database."
  type        = map(string)
  default     = {}
}

variable "enforce_tag_policy" {
  description = "Fail the plan when a database lacks a required policy tag (null = policy enforce_required)."
  type        = bool
  default     = false
}
