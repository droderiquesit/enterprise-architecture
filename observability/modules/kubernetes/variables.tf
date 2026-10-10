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
    How the Datadog API key reaches the cluster (never through Terraform: no key in variables, plan or state):
      dsv_secret_backend : (default) the chart Secret holds only the reference ENC[<dsv.api_key_ref>]. Node Agents
                           (all containers) and cluster-checks runners resolve it with secret_backend_command =
                           dsv-fetch agent-backend (ConfigMap-mounted stdlib script, mode 0500, run by the Agent
                           image's python3), authenticating to DSV with AKS workload identity on the service account
                           "datadog". Fluent Bit gets the key from a dsv-fetch init container (env-yaml on an
                           in-memory emptyDir). The Cluster Agent image has no Python interpreter, so it cannot run
                           dsv-fetch: set cluster_agent_secret_name to a Secret synced by the Delinea dsv-k8s syncer
                           (otherwise Cluster Agent features that need the key - orchestrator explorer, its own
                           telemetry - fail to authenticate; cluster-check dispatch keeps working).
      existing           : documented fallback - a Kubernetes Secret "<secret_name>" (key api-key) maintained in both
                           namespaces by the Delinea DSV Kubernetes syncer (dsv-k8s) or another operator-run sync.
  EOT
  type = object({
    mode                      = optional(string, "dsv_secret_backend")
    secret_name               = optional(string, "datadog-api-key")
    cluster_agent_secret_name = optional(string)
  })
  default = {}
  validation {
    condition     = contains(["dsv_secret_backend", "existing"], var.api_key.mode)
    error_message = "api_key.mode must be dsv_secret_backend or existing."
  }
}

variable "dsv" {
  description = <<-EOT
    Delinea DSV settings (non-secret): api_key_ref (dsv://...), tenant/tld or base_url, the dsv-fetch image for the
    Fluent Bit init container, the dsv_fetch.py source for the Agent secret backend ConfigMap (null = this package's
    observability/images/dsv-fetch/dsv_fetch.py), and the workload identity client id (user-assigned identity
    federated with the service accounts datadog/datadog and fluent-bit/fluent-bit, mapped to a DSV user).
  EOT
  type = object({
    api_key_ref        = string
    tenant             = optional(string)
    tld                = optional(string, "com")
    base_url           = optional(string)
    fetch_image        = optional(string)
    script_source      = optional(string)
    identity_client_id = optional(string)
  })
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.dsv.api_key_ref))
    error_message = "dsv.api_key_ref must be a dsv:// reference."
  }
  validation {
    condition     = var.dsv.tenant != null || var.dsv.base_url != null
    error_message = "dsv needs tenant or base_url."
  }
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
    agent_tag          = optional(string) # null = fleet policy agent.version (7.84.2)
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

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default): log pipeline + node collector, APM mode / SSI library versions, profiling, Agent products and Remote Configuration."
  type        = any
  default     = null
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default): cluster tags, podLabelsAsTags and the Fluent Bit label map."
  type        = any
  default     = null
}

variable "identity" {
  description = "Canonical tag values of the cluster's infrastructure (team, owner, region, application, domain, tier, cost_center, ...). env comes from datadog.env, service defaults to the policy default."
  type        = map(string)
  default     = {}
}

variable "log_pipeline" {
  description = "Override the fleet policy: observability_pipelines | fluent_bit_direct (null = policy)."
  type        = string
  default     = null
}

variable "op_logs_url" {
  description = "Observability Pipelines Worker Datadog Agent source, e.g. http://<worker>:8282 (obs-telemetry-transport contract aggregator.agent_logs_url). Null with op_worker.enabled = false and observability_pipelines mode = plan error."
  type        = string
  default     = null
}

variable "apm" {
  description = <<-EOT
    Single Step Instrumentation (fleet policy apm.mode = datadog): namespaces whose pods get the Datadog library
    injected by the Cluster Agent admission controller (target-based selection, Cluster Agent >= 7.64), injection
    mode, and a securityContext for the injected init containers that satisfies the restricted Pod Security Standard.
  EOT
  type = object({
    namespaces     = optional(list(string), ["hello"])
    injection_mode = optional(string, "")
    restricted_pss = optional(bool, true)
  })
  default = {}
}

variable "op_worker" {
  description = <<-EOT
    Optional Observability Pipelines Worker on this cluster (Helm chart observability-pipelines-worker): Datadog
    Agents and in-cluster Fluent Bit send to it instead of the Container Apps Worker. The API key comes from an
    existing Secret (key api-key) maintained by the Delinea dsv-k8s syncer; persistent volumes back the disk buffers.
  EOT
  type = object({
    enabled             = optional(bool, false)
    pipeline_id         = optional(string)
    chart_version       = optional(string, "2.22.0")
    image_tag           = optional(string, "2.22.0")
    namespace           = optional(string, "observability-pipelines")
    api_key_secret_name = optional(string, "datadog-api-key")
    replicas            = optional(number, 2)
    max_replicas        = optional(number, 6)
    cpu_request         = optional(string, "1")
    memory_request      = optional(string, "2Gi")
    memory_limit        = optional(string, "4Gi")
    persistence_size    = optional(string, "20Gi")
    storage_class       = optional(string, "managed-csi")
    # extra non-secret Worker env (e.g. modules/observability-pipeline worker_env: Kafka bootstrap / SASL username of
    # the Event Hubs source) and secret env from existing Secrets kept by the Delinea dsv-k8s syncer
    # (name -> {secret_name, key}, e.g. DD_OP_SOURCE_KAFKA_SASL_PASSWORD); never values
    env        = optional(map(string), {})
    secret_env = optional(map(object({ secret_name = string, key = string })), {})
  })
  default = {}
  validation {
    condition     = !var.op_worker.enabled || var.op_worker.pipeline_id != null
    error_message = "op_worker.enabled needs op_worker.pipeline_id (modules/observability-pipeline output)."
  }
}
