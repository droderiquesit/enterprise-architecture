variable "databases" {
  description = <<-EOT
    Database endpoints to monitor with Datadog Database Monitoring (keyed by a stable name).
      engine          : postgres | mysql | sqlserver   (DBM-supported engines only)
      deployment_type : postgres/mysql -> flexible_server ; sqlserver -> sql_database | managed_instance | virtual_machine
      auth            : password (password_ref required) | managed_identity (postgres + sqlserver only)
      password_ref    : how the Agent resolves the password - NEVER a literal:
                          dsv        name=dsv://<path>#<element> -> ENC[dsv://...] (secret backend dsv-fetch agent-backend)
                          k8s_secret name=<ns>/<secret>/<key>     -> ENC[k8s_secret@...]
                          file       name=<absolute path>         -> ENC[file@...]
                          env        name=<ENV_VAR>               -> %%env_<ENV_VAR>%% (cluster checks / autodiscovery)
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
    condition     = alltrue([for d in values(var.databases) : d.auth == "managed_identity" ? d.managed_identity_client_id != null : (d.password_ref != null && contains(["dsv", "k8s_secret", "file", "env"], try(d.password_ref.kind, "")))])
    error_message = "auth = password needs password_ref {kind = dsv|k8s_secret|file|env, name}; auth = managed_identity needs managed_identity_client_id."
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
      aci          : a Datadog Agent container group in the observability subnet (this module creates it)
      cluster_checks : rendered as cluster checks for an existing Datadog Cluster Agent (modules/kubernetes cluster_checks input)
      none         : only render configs (e.g. drop them into an existing host Agent's conf.d)
  EOT
  type        = string
  default     = "aci"
  validation {
    condition     = contains(["aci", "cluster_checks", "none"], var.hosting)
    error_message = "hosting must be aci, cluster_checks or none."
  }
}

variable "aci" {
  description = "ACI hosting: existing subnet (delegated to Microsoft.ContainerInstance/containerGroups), RG, user-assigned identity mapped to a DSV user with read on the API key / DB password paths, DSV endpoint."
  type = object({
    name                = string
    resource_group_name = string
    location            = string
    subnet_id           = string
    identity_id         = string
    identity_client_id  = string
    api_key_ref         = string
    dsv = object({
      tenant   = optional(string)
      tld      = optional(string, "com")
      base_url = optional(string)
    })
    dsv_fetch_source = optional(string)
    image            = optional(string, "datadog/agent:7.84.2")
    cpu              = optional(number, 1)
    memory_gb        = optional(number, 2)
  })
  default = null
}

variable "datadog" {
  type = object({
    site = string
    env  = string
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "sqlserver_driver" {
  type    = string
  default = "ODBC Driver 18 for SQL Server"
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
