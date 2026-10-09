variable "cluster_name" {
  description = "Kubernetes cluster name as it should appear in Datadog (datadog.clusterName / kube_cluster_name)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]{0,78}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumerics, dots and dashes (Datadog cluster name rules), max 80 chars."
  }
}

variable "datadog" {
  type = object({
    site       = string
    env        = string
    extra_tags = optional(map(string), {})
  })
}

variable "api_key" {
  description = <<-EOT
    How the Datadog API key reaches the cluster:
      write_only : this module creates Secret "<secret_name>" (key api-key) in both namespaces from the
                   EPHEMERAL input api_key_wo (kubernetes_secret_v1.data_wo: the value is never stored in
                   Terraform state or plan). Bump revision to rotate.
      existing   : the caller manages the Secret (e.g. Secrets Store CSI driver + Azure Key Vault provider
                   with secretObjects sync, External Secrets) in both namespaces.
  EOT
  type = object({
    mode        = optional(string, "write_only")
    secret_name = optional(string, "datadog-api-key")
    revision    = optional(number, 1)
  })
  default = {}
  validation {
    condition     = contains(["write_only", "existing"], var.api_key.mode)
    error_message = "api_key.mode must be write_only or existing."
  }
}

variable "api_key_wo" {
  description = "Datadog API key (ephemeral: read it with `ephemeral \"azurerm_key_vault_secret\"` in the caller)."
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
}

variable "namespaces" {
  type = object({
    datadog    = optional(string, "datadog")
    fluent_bit = optional(string, "fluent-bit")
    create     = optional(bool, true)
  })
  default = {}
}

variable "charts" {
  description = "Pinned chart versions (helm.datadoghq.com index 2026-10-09: datadog 3.253.2; fluent.github.io: fluent-bit 0.58.3 = app 5.1.3)."
  type = object({
    datadog_version    = optional(string, "3.253.2")
    datadog_repository = optional(string, "https://helm.datadoghq.com")
    fluent_bit_version = optional(string, "0.58.3")
    fluent_repository  = optional(string, "https://fluent.github.io/helm-charts")
    agent_tag          = optional(string, "7.84.2")
    fluent_bit_image   = optional(string, "fluent/fluent-bit")
    fluent_bit_tag     = optional(string, "5.1.3")
  })
  default = {}
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.charts.datadog_version)) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.charts.fluent_bit_version))
    error_message = "Chart versions must be pinned (x.y.z)."
  }
}

variable "features" {
  type = object({
    apm                    = optional(bool, true)
    process_collection     = optional(bool, false)
    cluster_checks_runner  = optional(bool, true)
    cluster_agent_replicas = optional(number, 1)
    operator_subchart      = optional(bool, false)
    service_discovery      = optional(bool, false)
    # aks_rotation: AKS with kubelet serving-certificate rotation (default on current AKS) -> providers.aks.enabled
    # aks_hostca  : older AKS without rotation -> kubelet host = spec.nodeName + hostCAPath kubeletserver.crt
    # insecure    : datadog.kubelet.tlsVerify=false (last resort, documented by Datadog for AKS)
    kubelet_tls_mode = optional(string, "aks_rotation")
    is_aks           = optional(bool, true)
  })
  default = {}
  validation {
    condition     = contains(["aks_rotation", "aks_hostca", "insecure"], var.features.kubelet_tls_mode)
    error_message = "features.kubelet_tls_mode must be aks_rotation, aks_hostca or insecure."
  }
}

variable "cluster_checks" {
  description = "Cluster-check configs (e.g. DBM from modules/dbm output cluster_check_confd): file name -> conf.yaml content."
  type        = map(string)
  default     = {}
}

variable "cluster_check_env" {
  description = "Extra env for the cluster-checks runners, e.g. DB passwords from Secrets: name -> {secret_name, secret_key}."
  type = map(object({
    secret_name = string
    secret_key  = string
  }))
  default = {}
}

variable "fluent_bit" {
  type = object({
    exclude_namespaces = optional(list(string), ["kube-system", "datadog", "fluent-bit", "gatekeeper-system", "calico-system", "tigera-operator"])
    throttle_rate      = optional(number, 2000)
    tolerations        = optional(list(map(string)), [{ operator = "Exists" }])
  })
  default = {}
}

variable "resources" {
  description = "Bounded requests/limits."
  type = object({
    agent_cpu_request    = optional(string, "200m")
    agent_memory_request = optional(string, "256Mi")
    agent_memory_limit   = optional(string, "512Mi")
    trace_memory_limit   = optional(string, "256Mi")
    process_memory_limit = optional(string, "256Mi")
    cluster_agent_memory = optional(string, "256Mi")
    runner_memory_limit  = optional(string, "512Mi")
    fluent_bit_cpu       = optional(string, "100m")
    fluent_bit_memory    = optional(string, "128Mi")
    fluent_bit_mem_limit = optional(string, "512Mi")
  })
  default = {}
}
