variable "settings" {
  description = "obs-kubernetes settings."
  type = object({
    # kubelogin login mode for the helm/kubernetes providers: azurecli (pipeline after azure/login with
    # OIDC) | workloadidentity (federated token file) | msi (self-hosted agent identity)
    kubelogin_mode           = optional(string, "azurecli")
    kubelet_tls_mode         = optional(string, "aks_rotation")
    process_collection       = optional(bool, false)
    cluster_checks_runner    = optional(bool, true)
    datadog_chart_version    = optional(string, "3.253.2")
    fluent_bit_chart_version = optional(string, "0.58.3")
    exclude_namespaces       = optional(list(string), ["kube-system", "datadog", "fluent-bit", "gatekeeper-system", "calico-system", "tigera-operator"])
    ssi_namespaces           = optional(list(string), ["hello"]) # Single Step Instrumentation targets (fleet apm.mode = datadog)
    # DBM: auto = the platform-db contracts become cluster checks of the Cluster Agent (runners as the obs-dbm
    # identity); off = none here (obs-dbm settings.hosting = aci runs them on ACI instead)
    dbm                    = optional(string, "auto")
    dbm_identity_key       = optional(string, "obs-dbm")
    collector_identity_key = optional(string, "obs-collector")
    # per-cluster Datadog chart values, YAML documents applied last (sizing, tolerations, *.envDict, ...); the
    # module rejects overrides of the secret path
    values_overrides = optional(list(string), [])
  })
  default = {}
  validation {
    condition     = contains(["azurecli", "workloadidentity", "msi"], var.settings.kubelogin_mode)
    error_message = "settings.kubelogin_mode must be azurecli, workloadidentity or msi."
  }
  validation {
    condition     = contains(["auto", "off"], var.settings.dbm)
    error_message = "settings.dbm must be auto or off."
  }
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site = string
    api_key_ref  = string
    aggregator = optional(object({
      kind           = optional(string)
      fqdn           = optional(string)
      agent_logs_url = optional(string)
    }))
    env = optional(object({
      fleet = optional(map(string))
    }))
    secrets = object({
      tenant      = optional(string)
      tld         = optional(string)
      base_url    = string
      fetch_image = optional(string)
    })
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): the obs-collector identity (Agents, Cluster Agent, Fluent Bit service accounts), the obs-dbm identity (cluster-checks runners for DBM) and the DSV base path."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
    secrets = optional(object({
      base_path = string
    }))
  })
}

# Optional database contracts (obs-kubernetes optional_consumes): only their `dbm` block is read
# (platform-db-*.v1 $defs/dbm) - same mapping as obs-dbm (modules/dbm/contracts).
variable "platform_db_postgresql" {
  description = "Optional platform-db-postgresql contract (null = no such database): servers and databases to monitor with DBM."
  type        = any
  default     = null
}
variable "platform_db_mysql" {
  description = "Optional platform-db-mysql contract (null = no such database): servers and databases to monitor with DBM."
  type        = any
  default     = null
}
variable "platform_db_sql" {
  description = "Optional platform-db-sql contract (null = no such database): servers and databases to monitor with DBM."
  type        = any
  default     = null
}
variable "platform_db_sqlmi" {
  description = "Optional platform-db-sqlmi contract (null = no such database): servers and databases to monitor with DBM."
  type        = any
  default     = null
}
variable "platform_db_sqlvm" {
  description = "Optional platform-db-sqlvm contract (null = no such database): servers and databases to monitor with DBM."
  type        = any
  default     = null
}

variable "platform_aks" {
  description = "platform-aks contract (fields used)."
  type = object({
    resource_group_name = string
    cluster_id          = string
    cluster_name        = string
    oidc_issuer_url     = string
    access = object({
      private_cluster     = bool
      entra_server_app_id = optional(string)
    })
  })
}

variable "artifacts" {
  description = "Immutable build outputs keyed by artifact component id (tools/deploy/artifacts.py tfvars); this root uses img-dsv-fetch (digest-pinned)."
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
