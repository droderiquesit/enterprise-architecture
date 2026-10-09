variable "databases" {
  description = <<-EOT
    Database endpoints to monitor with Datadog Database Monitoring (keyed by a stable name).
      engine          : postgres | mysql | sqlserver   (DBM-supported engines only)
      deployment_type : postgres/mysql -> flexible_server ; sqlserver -> sql_database | managed_instance | virtual_machine
      auth            : password (password_ref required) | managed_identity (postgres + sqlserver only)
      password_ref    : how the Agent resolves the password - NEVER a literal:
                          key_vault  name=<Key Vault secret name>  -> ENC[<name>]  (secret_backend_type azure.keyvault)
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
    tags        = optional(map(string), {})
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
    condition     = alltrue([for d in values(var.databases) : d.auth == "managed_identity" ? d.managed_identity_client_id != null : (d.password_ref != null && contains(["key_vault", "k8s_secret", "file", "env"], try(d.password_ref.kind, "")))])
    error_message = "auth = password needs password_ref {kind = key_vault|k8s_secret|file|env, name}; auth = managed_identity needs managed_identity_client_id."
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
  description = "ACI hosting: existing subnet (delegated to Microsoft.ContainerInstance/containerGroups), RG, identity with Key Vault Secrets User."
  type = object({
    name                = string
    resource_group_name = string
    location            = string
    subnet_id           = string
    identity_id         = string
    identity_client_id  = string
    key_vault_uri       = string
    api_key_secret_name = optional(string, "datadog-api-key")
    image               = optional(string, "datadog/agent:7.84.2")
    cpu                 = optional(number, 1)
    memory_gb           = optional(number, 2)
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
