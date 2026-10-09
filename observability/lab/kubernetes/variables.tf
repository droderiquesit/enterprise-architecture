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
  })
}

variable "platform_aks" {
  description = "platform-aks contract (fields used)."
  type = object({
    resource_group_name = string
    cluster_id          = string
    cluster_name        = string
    access = object({
      private_cluster     = bool
      entra_server_app_id = optional(string)
    })
  })
}

variable "datadog_api_key" {
  description = "Datadog API key (EPHEMERAL: set TF_VAR_datadog_api_key from Key Vault secret datadog-api-key in the pipeline). Never stored."
  type        = string
  ephemeral   = true
  sensitive   = true
}
