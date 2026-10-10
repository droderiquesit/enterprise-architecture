variable "settings" {
  description = "obs-dbm settings."
  type = object({
    # auto (default): cluster_checks when the platform-aks contract is present (obs-kubernetes runs the checks on the
    # Cluster Agent from the same platform-db contracts), else aci. Explicit: cluster_checks | aci | none (render only)
    hosting      = optional(string, "auto")
    subnet_key   = optional(string, "aci") # ACI needs a Microsoft.ContainerInstance/containerGroups-delegated subnet (foundation-network `aci`)
    identity_key = optional(string, "obs-dbm")
    cpu          = optional(number, 1)
    memory_gb    = optional(number, 2)
  })
  default = {}
  validation {
    condition     = contains(["auto", "aci", "cluster_checks", "none"], var.settings.hosting)
    error_message = "settings.hosting must be auto, aci, cluster_checks or none."
  }
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      tenant      = optional(string)
      tld         = optional(string)
      base_url    = string
      fetch_image = optional(string)
    })
  })
}

variable "platform_aks" {
  description = "Optional platform-aks contract: present = a cluster exists, so settings.hosting = auto runs DBM as cluster checks (obs-kubernetes) and creates no ACI Agent."
  type        = any
  default     = null
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

variable "artifacts" {
  description = "Immutable build outputs keyed by artifact component id (tools/deploy/artifacts.py tfvars); this root uses img-dsv-fetch (digest-pinned): the ACI Agent's init container copies the static dsv-fetch binary (secret backend) out of it."
  type = map(object({
    name    = optional(string)
    image   = optional(string)
    digest  = optional(string)
    version = optional(string)
    commit  = optional(string)
    tag     = optional(string)
  }))
  default = {}
  validation {
    condition = alltrue([for a in values(var.artifacts) : a.image == null || can(regex(
      "^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", coalesce(a.image, "x")
    ))])
    error_message = "artifacts[*].image must be digest-pinned (<registry>/<repo>@sha256:<64 hex>)."
  }
}
