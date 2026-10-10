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

variable "dsv" {
  description = <<-EOT
    Delinea DSV settings (non-secret) - the ONE secret path of the Datadog Agents (ADR-0001 section 14):
      api_key_ref        dsv:// reference of the Datadog API key; the chart Secret holds only ENC[<api_key_ref>]
      tenant/tld|base_url DSV endpoint (DSV_* env of dsv-fetch)
      fetch_image        digest-pinned dsv-fetch image (registry artifact img-dsv-fetch, >= 2.0.0: static binary at
                         /opt/dsv-fetch/dsv-fetch). Init container dsv-fetch-install copies it into an in-memory emptyDir
                         of the node Agent, Cluster Agent and cluster-checks runner pods (secret_backend_command,
                         `agent-backend`); `init` containers of the Fluent Bit fallback / OP Worker run it directly.
      identity_client_id user-assigned identity (workload identity) of the service accounts datadog/datadog,
                         datadog/datadog-cluster-agent (and fluent-bit/fluent-bit, the OP Worker's) - mapped to a DSV
                         user with read on the API key path
      cluster_checks_identity_client_id  optional identity of datadog/datadog-cluster-checks (null = identity_client_id),
                         e.g. the DBM identity that reads the DB password paths and logs in to Entra-enabled databases
  EOT
  type = object({
    api_key_ref                       = string
    tenant                            = optional(string)
    tld                               = optional(string, "com")
    base_url                          = optional(string)
    fetch_image                       = string
    identity_client_id                = string
    cluster_checks_identity_client_id = optional(string)
  })
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.dsv.api_key_ref))
    error_message = "dsv.api_key_ref must be a dsv:// reference."
  }
  validation {
    condition     = var.dsv.tenant != null || var.dsv.base_url != null
    error_message = "dsv needs tenant or base_url."
  }
  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.dsv.fetch_image))
    error_message = "dsv.fetch_image must be the digest-pinned dsv-fetch image (<registry>/<repo>@sha256:<64 hex>, registry artifact img-dsv-fetch)."
  }
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.dsv.identity_client_id)) && (var.dsv.cluster_checks_identity_client_id == null || can(regex("^[0-9a-fA-F-]{36}$", coalesce(var.dsv.cluster_checks_identity_client_id, "x"))))
    error_message = "dsv.identity_client_id (and cluster_checks_identity_client_id when set) must be managed identity client ids (workload identity)."
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
  description = "Pinned chart versions (helm.datadoghq.com index 2026-10-09: datadog 3.253.2; fluent.github.io: fluent-bit 0.58.3 = app 5.1.3). The Agent / Cluster Agent image tag is the fleet policy agent.version (no input here)."
  type = object({
    datadog_version    = optional(string, "3.253.2")
    datadog_repository = optional(string, "https://helm.datadoghq.com")
    fluent_bit_version = optional(string, "0.58.3")
    fluent_repository  = optional(string, "https://fluent.github.io/helm-charts")
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
    apm                   = optional(bool, true)
    process_collection    = optional(bool, false)
    cluster_checks_runner = optional(bool, true)
    operator_subchart     = optional(bool, false)
    service_discovery     = optional(bool, false)
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
  description = "Cluster-check configs dispatched by the Cluster Agent to the cluster-checks runners (e.g. DBM from modules/dbm output cluster_check_confd): file name -> conf.yaml content. Secrets only as ENC[dsv://...] handles (resolved by the runners' dsv-fetch secret backend)."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for c in values(var.cluster_checks) : !strcontains(c, "ENC[k8s_secret@") && !strcontains(c, "%%env_")])
    error_message = "cluster_checks: secrets must be ENC[dsv://...] references (no Kubernetes Secret / env indirection)."
  }
}

variable "values_overrides" {
  description = <<-EOT
    Per-cluster Datadog chart values, applied LAST (after values/base.yaml and the computed fleet layer): a list of
    YAML documents, e.g. [file("clusters/aks-prod.yaml")] - sizing (agents.containers.*.resources, clusterAgent.replicas),
    tolerations, extra env via *.envDict, ... The secret path cannot be overridden: datadog.apiKey / apiKeyExistingSecret /
    secretBackend / env, and the volumes, volumeMounts and service account annotations of agents, clusterAgent and
    clusterChecksRunner are rejected (lists replace, they would drop the dsv-fetch wiring).
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for v in var.values_overrides : can(keys(yamldecode(v)))])
    error_message = "values_overrides: every entry must be a YAML mapping (chart values document)."
  }
  validation {
    condition = alltrue([for v in var.values_overrides : alltrue(concat(
      [for k in ["apiKey", "apiKeyExistingSecret", "secretBackend", "env"] : !can(yamldecode(v).datadog[k])],
      flatten([for c in ["agents", "clusterAgent", "clusterChecksRunner"] : [
        !can(yamldecode(v)[c].volumes), !can(yamldecode(v)[c].volumeMounts), !can(yamldecode(v)[c].rbac.serviceAccountAnnotations),
      ]]),
    ))])
    error_message = "values_overrides must not change the secret path (datadog.apiKey, apiKeyExistingSecret, secretBackend, env; volumes / volumeMounts / rbac.serviceAccountAnnotations of agents, clusterAgent, clusterChecksRunner). Use *.envDict for extra env."
  }
}

variable "fluent_bit" {
  description = "Fluent Bit DaemonSet - fallback only (fleet node collector fluent_bit / log_pipeline = fluent_bit_direct)."
  type = object({
    exclude_namespaces = optional(list(string), ["kube-system", "datadog", "fluent-bit", "gatekeeper-system", "calico-system", "tigera-operator"])
    throttle_rate      = optional(number, 2000)
    tolerations        = optional(list(map(string)), [{ operator = "Exists" }])
    cpu_request        = optional(string, "100m")
    memory_request     = optional(string, "128Mi")
    memory_limit       = optional(string, "512Mi")
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
    Agents and in-cluster Fluent Bit send to it instead of the Container Apps Worker. The API key and secret_env values
    are read from Delinea DSV by a dsv-fetch init container (workload identity dsv.identity_client_id on the Worker's
    service account opw-observability-pipelines-worker) into an in-memory env file; the chart Secret holds only the
    ENC[] reference. Persistent volumes back the disk buffers.
  EOT
  type = object({
    enabled          = optional(bool, false)
    pipeline_id      = optional(string)
    chart_version    = optional(string, "2.22.0")
    image_tag        = optional(string, "2.22.0")
    namespace        = optional(string, "observability-pipelines")
    replicas         = optional(number, 2)
    max_replicas     = optional(number, 6)
    cpu_request      = optional(string, "1")
    memory_request   = optional(string, "2Gi")
    memory_limit     = optional(string, "4Gi")
    persistence_size = optional(string, "20Gi")
    storage_class    = optional(string, "managed-csi")
    # extra non-secret Worker env (e.g. modules/observability-pipeline worker_env: Kafka bootstrap / SASL username of
    # the Event Hubs source) and secret env as DSV references (name -> dsv://..., e.g. DD_OP_SOURCE_KAFKA_SASL_PASSWORD
    # = dsv://eh/dev/eventhub-opw-listen#value); never values
    env        = optional(map(string), {})
    secret_env = optional(map(string), {})
  })
  default = {}
  validation {
    condition     = !var.op_worker.enabled || var.op_worker.pipeline_id != null
    error_message = "op_worker.enabled needs op_worker.pipeline_id (modules/observability-pipeline output)."
  }
  validation {
    condition     = alltrue([for k, v in var.op_worker.secret_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", v))])
    error_message = "op_worker.secret_env: NAME -> dsv://<path>#<element> references only."
  }
}
