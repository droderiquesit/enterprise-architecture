variable "settings" {
  description = "obs-kubernetes-aro settings (environment.yaml components.obs-kubernetes-aro)."
  type = object({
    collector_identity_key = optional(string, "obs-collector")
    process_collection     = optional(bool, false)
    cluster_checks_runner  = optional(bool, true)
    datadog_chart_version  = optional(string, "3.253.2")
    # Agent container-log exclusions (kube_namespace regexes): the collector itself and the OpenShift platform
    # namespaces (ARO service logging ships those; collecting them would cost without serving the applications)
    exclude_namespaces = optional(list(string), ["datadog", "kube-system", "^openshift-"])
    ssi_namespaces     = optional(list(string), ["hello"]) # Single Step Instrumentation targets (fleet apm.mode = datadog)
    # Kubernetes API credentials of the helm / kubernetes providers (README "Provider authentication"):
    #   admin_kubeconfig  (default) ephemeral ARM listAdminCredentials - nothing in plan or state
    #   kubeconfig        a kubeconfig file prepared on the deploy agent before Terraform runs (settings.kubeconfig_path,
    #                     e.g. `oc login --token` of a least-privilege deployer service account whose token lives in DSV)
    kube_auth       = optional(string, "admin_kubeconfig")
    kubeconfig_path = optional(string)
    # PEM of the ARO API server CA, only when the admin kubeconfig carries no certificate-authority-data and the
    # deploy agents do not trust the API certificate (not a secret)
    api_ca_certificate = optional(string)
    # per-cluster Datadog chart values, YAML documents applied last (sizing, tolerations, *.envDict, ...); the module
    # rejects overrides of the secret path
    values_overrides = optional(list(string), [])
  })
  default = {}
  validation {
    condition     = contains(["admin_kubeconfig", "kubeconfig"], var.settings.kube_auth) && (var.settings.kube_auth != "kubeconfig" || var.settings.kubeconfig_path != null)
    error_message = "settings.kube_auth must be admin_kubeconfig or kubeconfig (kubeconfig needs settings.kubeconfig_path)."
  }
  validation {
    condition     = var.settings.api_ca_certificate == null || can(regex("-----BEGIN CERTIFICATE-----", coalesce(var.settings.api_ca_certificate, "x")))
    error_message = "settings.api_ca_certificate must be a PEM certificate."
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
  description = "foundation-identity contract v2 (fields used): the obs-collector identity (node Agent, Cluster Agent, cluster-checks runner service accounts)."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "platform_aro" {
  description = "platform-aro contract v1 (fields used). enabled = false (the default, prerequisites in platform/compute/aro/README.md) -> this root creates nothing."
  type = object({
    enabled         = bool
    cluster_id      = optional(string)
    cluster_name    = optional(string)
    api_server_url  = optional(string)
    oidc_issuer_url = optional(string)
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
