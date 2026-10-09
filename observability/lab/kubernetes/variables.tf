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
    dbm_cluster_checks       = optional(map(string), {}) # from obs-dbm (hosting = cluster_checks): file -> conf
    # dsv_secret_backend (default): Agents + Fluent Bit read the key from DSV with workload identity;
    # existing: documented fallback, Secret <synced_secret_name> maintained by the Delinea dsv-k8s syncer
    api_key_mode              = optional(string, "dsv_secret_backend")
    synced_secret_name        = optional(string, "datadog-api-key")
    cluster_agent_secret_name = optional(string) # dsv-k8s syncer Secret for the Cluster Agent (no Python -> no dsv-fetch)
    collector_identity_key    = optional(string, "obs-collector")
  })
  default = {}
  validation {
    condition     = contains(["azurecli", "workloadidentity", "msi"], var.settings.kubelogin_mode)
    error_message = "settings.kubelogin_mode must be azurecli, workloadidentity or msi."
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

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): the obs-collector identity federated with the Datadog / Fluent Bit service accounts."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
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
