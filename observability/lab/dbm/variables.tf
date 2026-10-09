variable "settings" {
  description = "obs-dbm settings."
  type = object({
    hosting      = optional(string, "aci") # aci | cluster_checks (render for obs-kubernetes settings.dbm_cluster_checks) | none
    subnet_key   = optional(string, "aci") # ACI needs a Microsoft.ContainerInstance/containerGroups-delegated subnet (foundation-network `aci`)
    identity_key = optional(string, "obs-dbm")
    cpu          = optional(number, 1)
    memory_gb    = optional(number, 2)
  })
  default = {}
  validation {
    condition     = contains(["aci", "cluster_checks", "none"], var.settings.hosting)
    error_message = "settings.hosting must be aci, cluster_checks or none."
  }
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      tenant   = optional(string)
      tld      = optional(string)
      base_url = string
    })
  })
}

variable "foundation_network" {
  description = "foundation-network contract (fields used)."
  type = object({
    subnets = map(object({
      id   = string
      name = string
    }))
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): the obs-dbm identity (DSV reader on ACI) and the DSV base path."
  type = object({
    identities = map(object({
      id        = string
      client_id = string
      name      = string
    }))
    secrets = object({
      base_path = string
    })
  })
}

# Optional database contracts: only their `dbm` block is read (platform-db-*.v1 $defs/dbm).
variable "platform_db_postgresql" {
  type    = any
  default = null
}
variable "platform_db_mysql" {
  type    = any
  default = null
}
variable "platform_db_sql" {
  type    = any
  default = null
}
variable "platform_db_sqlmi" {
  type    = any
  default = null
}
variable "platform_db_sqlvm" {
  type    = any
  default = null
}
