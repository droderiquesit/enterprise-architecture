# Datadog Agent (Helm chart, DaemonSet + Cluster Agent + cluster-checks runners) on an EXISTING cluster - the fleet
# collector of the node: metrics, APM (Single Step Instrumentation of the Datadog libraries, profiler), OTLP for
# otel-mode workloads, DBM cluster checks and, with the fleet policy defaults (log_pipeline = observability_pipelines,
# Agent log collection), container logs shipped to the Observability Pipelines Worker. One log collector per node: the
# Fluent Bit DaemonSet is installed only for the fallback (node collector fluent_bit / log_pipeline =
# fluent_bit_direct), and then the Agent's log collection is off (README-transport.md).
#
# Chart values are layered YAML (values = [base, fleet, overrides...], later wins):
#   values/base.yaml       static, reviewed defaults (sizing, OTLP, dsv-fetch volume wiring)
#   local.fleet_values     computed here from the fleet / tag policies and the inputs only (site, cluster name, tags,
#                          log collector, SSI targets, versions, OP Worker URL, DSV references, feature flags)
#   var.values_overrides   per-cluster YAML documents (validated: they cannot change the secret path)
#
# Secrets (ADR-0001 section 14): ONE path, nothing secret passes through Terraform or a Kubernetes Secret. The node
# Agent, the Cluster Agent and the cluster-checks runners resolve api_key ENC[dsv://...] (and DB passwords of cluster
# checks) with secret_backend_command = the static dsv-fetch binary (`agent-backend`), copied by the init container
# dsv-fetch-install (postrender/dsv-fetch-init.sh) into an in-memory emptyDir, authenticating to Delinea DSV with AKS
# workload identity. The Fluent Bit fallback and the optional in-cluster OP Worker get the key from a dsv-fetch `init`
# container (in-memory emptyDir); the chart Secrets hold only the ENC[] reference.
module "fleet" {
  source       = "../fleet-policy"
  policy       = var.fleet_policy
  architecture = "aks"
  env          = var.datadog.env
  overrides    = var.log_pipeline == null ? {} : { log_pipeline = var.log_pipeline }
}

module "tags" {
  source           = "../tagging"
  policy           = var.tag_policy
  identity         = merge(var.identity, { env = var.datadog.env })
  extra_tags       = var.datadog.extra_tags
  enforce_required = false
}

locals {
  op_mode        = module.fleet.log_pipeline == "observability_pipelines"
  agent_logs     = module.fleet.node_collector == "agent"
  fluent_bit_on  = !local.agent_logs
  op_svc_url     = var.op_worker.enabled ? "http://opw-observability-pipelines-worker.${var.op_worker.namespace}.svc.cluster.local:8282" : null
  op_logs_url    = coalesce(local.op_svc_url, var.op_logs_url, "unset")
  op_fluent_host = var.op_worker.enabled ? "opw-observability-pipelines-worker.${var.op_worker.namespace}.svc.cluster.local" : try(regex("^https?://([^:/]+)", var.op_logs_url)[0], "unset")
  apm_datadog    = try(module.fleet.sections.apm.mode, "datadog") == "datadog"
  libs           = module.fleet.apm.library_versions
  agent_cfg      = module.fleet.agent
  # single Agent pin: fleet policy agent.version (versions.yaml images.datadog_agent carries the same version); no
  # fallback - a policy without it fails the plan (precondition on helm_release.datadog)
  agent_version  = try(tostring(module.fleet.agent.version), null)
  agent_registry = try(regex("^(.+)/agent$", module.fleet.agent.image)[0], null)
  # SSI library versions: chart format "v<major>" (datadog chart values example)
  dd_trace_versions = { for lang, v in local.libs : lang => startswith(v, "v") ? v : "v${v}" }
  profiling_on      = try(module.fleet.sections.profiling.enabled, true)
  ssi_targets = [{
    name              = "enterprise-workloads"
    namespaceSelector = { matchNames = var.apm.namespaces }
    ddTraceVersions   = local.dd_trace_versions
    # language-agnostic library settings; per-workload profiler types / DSM / DBM come from the instrumentation hook
    ddTraceConfigs = concat(
      local.profiling_on ? [{ name = "DD_PROFILING_ENABLED", value = "auto" }] : [],
      [{ name = "DD_LOGS_INJECTION", value = "true" }, { name = "DD_RUNTIME_METRICS_ENABLED", value = "true" }],
    )
  }]
  # restricted Pod Security Standard namespaces: securityContext of the injected library init containers
  ssi_dca_env = local.apm_datadog && var.apm.restricted_pss ? [
    { name = "DD_ADMISSION_CONTROLLER_AUTO_INSTRUMENTATION_INIT_SECURITY_CONTEXT", value = local.ssi_init_security_context },
  ] : []
  ssi_init_security_context = jsonencode({
    allowPrivilegeEscalation = false
    capabilities             = { drop = ["ALL"] }
    runAsNonRoot             = true
    seccompProfile           = { type = "RuntimeDefault" }
  })

  dsv_base_url = coalesce(var.dsv.base_url, "https://${coalesce(var.dsv.tenant, "unset")}.secretsvaultcloud.${coalesce(var.dsv.tld, "com")}/v1")
  dsv_env = concat(
    var.dsv.tenant == null ? [] : [{ name = "DSV_TENANT", value = var.dsv.tenant }],
    var.dsv.tld == null ? [] : [{ name = "DSV_TLD", value = var.dsv.tld }],
    [
      { name = "DSV_BASE_URL", value = local.dsv_base_url },
      { name = "DSV_AUTH", value = "azure" },
      { name = "DSV_TIMEOUT_SECONDS", value = "10" },
    ],
  )
  wi_labels = { "azure.workload.identity/use" = "true" }
  wi_annotations = {
    "azure.workload.identity/client-id" = var.dsv.identity_client_id
  }
  # cluster-checks runners: their own identity when given (DBM: DSV DB passwords + Entra database login)
  ccr_wi_annotations = {
    "azure.workload.identity/client-id" = coalesce(var.dsv.cluster_checks_identity_client_id, var.dsv.identity_client_id)
  }

  # Agent log shipping to the Observability Pipelines Worker (Datadog Agent source) - Datadog-documented env
  agent_log_env = local.agent_logs && local.op_mode ? [
    { name = "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED", value = "true" },
    { name = "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL", value = local.op_logs_url },
  ] : []
  # trace-agent drops health-probe resources (fleet policy apm.ignore_resources)
  apm_ignore_env = length(module.fleet.agent_apm_ignore_resources) == 0 ? [] : [
    { name = "DD_APM_IGNORE_RESOURCES", value = join(",", module.fleet.agent_apm_ignore_resources) },
  ]

  release    = "datadog"
  dd_ns      = var.namespaces.datadog
  fb_ns      = var.namespaces.fluent_bit
  all_tags   = module.tags.tags
  dd_tags    = module.tags.dd_tags_list
  managed_ns = toset(concat([local.dd_ns], local.fluent_bit_on ? [local.fb_ns] : []))

  kubelet = {
    aks_rotation = {}
    aks_hostca = {
      host       = { valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } }
      hostCAPath = "/etc/kubernetes/certs/kubeletserver.crt"
    }
    insecure = { tlsVerify = false }
  }[var.features.kubelet_tls_mode]

  # ---------------------------------------------------------------- layer 2: fleet (computed bits only)
  fleet_values = {
    datadog = merge(
      {
        site        = var.datadog.site
        clusterName = var.cluster_name
        tags        = local.dd_tags
        # one log collector per node: the Agent (-> Observability Pipelines Worker) or the Fluent Bit DaemonSet
        logs = { enabled = local.agent_logs, containerCollectAll = local.agent_logs }
        # pod label -> tag mapping of the tag policy (team, domain, tier, ...); every value is also in ad.datadoghq.com/tags
        podLabelsAsTags = module.tags.pod_labels_as_tags
        apm = merge(
          { socketEnabled = var.features.apm, portEnabled = var.features.apm },
          local.apm_datadog ? {
            instrumentation = merge({
              enabled = true
              targets = local.ssi_targets
            }, var.apm.injection_mode == "" ? {} : { injectionMode = var.apm.injection_mode })
          } : {},
        )
        networkMonitoring = { enabled = try(local.agent_cfg.network_monitoring, false) }
        serviceMonitoring = { enabled = try(local.agent_cfg.universal_service_monitoring, false) }
        processAgent      = { processCollection = var.features.process_collection || try(local.agent_cfg.process_collection, false) }
        operator          = { enabled = var.features.operator_subchart }
        discovery         = { enabled = var.features.service_discovery }
        # --- secret path (not overridable): the chart Secret holds only the reference, never the key
        apiKey = "ENC[${var.dsv.api_key_ref}]"
        secretBackend = {
          command   = "/opt/dsv-fetch/dsv-fetch"
          arguments = "agent-backend"
          timeout   = 30
        }
        # datadog.env reaches the node Agent containers only (helm template verified); the Cluster Agent and the
        # runners get the DSV env through their own env lists below
        env = concat(local.dsv_env, local.agent_log_env, local.apm_ignore_env)
      },
      # the collectors' own namespaces are never collected (no feedback loops / duplicates)
      local.agent_logs ? { containerExcludeLogs = join(" ", [for ns in var.fluent_bit.exclude_namespaces : "kube_namespace:${ns}"]) } : {},
      length(local.kubelet) > 0 ? { kubelet = local.kubelet } : {},
    )
    # Remote Configuration (Fleet Automation, APM sampling / SSI policies); preferred top-level key of the chart
    remoteConfiguration = { enabled = try(local.agent_cfg.remote_configuration, true) }
    providers           = { aks = { enabled = var.features.is_aks } }
    agents = {
      image = { tag = local.agent_version }
      # workload identity for dsv-fetch (service account "datadog")
      rbac             = { serviceAccountAnnotations = local.wi_annotations }
      additionalLabels = local.wi_labels
    }
    clusterAgent = {
      image            = { tag = local.agent_version }
      confd            = var.cluster_checks
      env              = concat(local.dsv_env, local.ssi_dca_env)
      rbac             = { serviceAccountAnnotations = local.wi_annotations }
      additionalLabels = local.wi_labels
    }
    clusterChecksRunner = {
      enabled          = var.features.cluster_checks_runner
      image            = { tag = local.agent_version }
      env              = local.dsv_env
      rbac             = { dedicated = true, serviceAccountAnnotations = local.ccr_wi_annotations }
      additionalLabels = local.wi_labels
    }
  }

  datadog_values = concat(
    # Agent registry from the fleet policy agent.image (<registry>/agent); the chart default otherwise
    [file("${path.module}/values/base.yaml"), yamlencode(merge(local.fleet_values, local.agent_registry == null ? {} : { registry = local.agent_registry }))],
    var.values_overrides,
  )
  # workloads that receive the dsv-fetch-install init container (postrender/dsv-fetch-init.sh --expect)
  backend_workloads = var.features.cluster_checks_runner ? 3 : 2
}

module "flb" {
  source             = "../fluent-bit"
  role               = "k8s-daemonset"
  datadog_site       = var.datadog.site
  static_tags        = merge(local.all_tags, { kube_cluster_name = var.cluster_name })
  exclude_namespaces = var.fluent_bit.exclude_namespaces
  throttle_rate      = var.fluent_bit.throttle_rate
  k8s_label_tags     = module.tags.pod_labels_as_tags
  log_destination    = local.op_mode ? "observability_pipelines" : "datadog"
  op_endpoint        = local.op_mode ? { host = local.op_fluent_host, port = 24224 } : null
}

locals {
  flb_cm_name = "fluent-bit-obs-config"
  # dsv-fetch `init` containers (Fluent Bit fallback, OP Worker): non-root, read-only rootfs, no capabilities
  fetch_security_context = { runAsNonRoot = true, allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
  # Fluent Bit fallback DaemonSet. Direct mode: dsv-fetch writes /dsv-secrets/fluentbit-env.yaml (DD_API_KEY) from DSV
  # with workload identity; observability_pipelines: no key on the edge -> no dsv-fetch.
  fb_needs_key = !local.op_mode
  fluent_bit_values = {
    kind              = "DaemonSet"
    image             = { repository = var.charts.fluent_bit_image, tag = var.charts.fluent_bit_tag }
    existingConfigMap = local.flb_cm_name
    args              = ["--workdir=/fluent-bit/etc", "--config=/fluent-bit/etc/eh/fluent-bit.yaml"]
    env = concat(
      # must precede FLB_OTLP_HOST=$(DD_AGENT_HOST) (Kubernetes dependent env expansion)
      [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }],
      [for k in sort(keys(module.flb.env)) : { name = k, value = module.flb.env[k] }],
    )
    initContainers = local.fb_needs_key ? [{
      name            = "dsv-fetch"
      image           = var.dsv.fetch_image
      args            = ["init", "--out", "/dsv-secrets", "--format", "env-yaml", "--env-yaml-name", "fluentbit-env.yaml", "--map", "DD_API_KEY=${var.dsv.api_key_ref}"]
      env             = local.dsv_env
      resources       = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "64Mi" } }
      securityContext = local.fetch_security_context
      volumeMounts    = [{ name = "dsv-secrets", mountPath = "/dsv-secrets" }]
    }] : []
    podLabels      = local.fb_needs_key ? local.wi_labels : {}
    serviceAccount = { create = true, annotations = local.fb_needs_key ? local.wi_annotations : {} }
    extraVolumes = [
      {
        name = "obs-config"
        configMap = {
          name = local.flb_cm_name
          items = [
            { key = "fluent-bit.yaml", path = "fluent-bit.yaml" },
            { key = "parsers.yaml", path = "parsers.yaml" },
            { key = "enterprise_hello.lua", path = "lua/enterprise_hello.lua" },
          ]
        }
      },
      { name = "dsv-secrets", emptyDir = { medium = "Memory", sizeLimit = "1Mi" } },
    ]
    extraVolumeMounts = [
      { name = "obs-config", mountPath = "/fluent-bit/etc/eh", readOnly = true },
      { name = "dsv-secrets", mountPath = "/dsv-secrets", readOnly = true },
    ]
    daemonSetVolumes = [
      { name = "varlog", hostPath = { path = "/var/log" } },
      { name = "flbstate", hostPath = { path = "/var/fluent-bit/state", type = "DirectoryOrCreate" } },
      { name = "etcmachineid", hostPath = { path = "/etc/machine-id", type = "File" } },
    ]
    daemonSetVolumeMounts = [
      { name = "varlog", mountPath = "/var/log", readOnly = true },
      { name = "flbstate", mountPath = "/var/fluent-bit/state" },
      { name = "etcmachineid", mountPath = "/etc/machine-id", readOnly = true },
    ]
    resources   = { requests = { cpu = var.fluent_bit.cpu_request, memory = var.fluent_bit.memory_request }, limits = { memory = var.fluent_bit.memory_limit } }
    tolerations = var.fluent_bit.tolerations
    podAnnotations = {
      # roll pods when config changes. Fluent Bit self-metrics are pushed over OTLP to the node Agent
      # (fluentbit_metrics input -> opentelemetry output) so names keep _total, e.g. fluentbit_output_errors_total.
      "checksum/obs-config" = module.flb.files_sha256
    }
    livenessProbe  = { httpGet = { path = "/api/v1/health", port = "http" } }
    readinessProbe = { httpGet = { path = "/api/v1/health", port = "http" } }
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces.create ? local.managed_ns : toset([])
  metadata {
    name   = each.value
    labels = { "app.kubernetes.io/managed-by" = "terraform", "observability/component" = "collection" }
  }
}

resource "kubernetes_config_map_v1" "fluent_bit" {
  count = local.fluent_bit_on ? 1 : 0
  metadata {
    name      = local.flb_cm_name
    namespace = local.fb_ns
  }
  data = {
    "fluent-bit.yaml"      = module.flb.files["fluent-bit.yaml"]
    "parsers.yaml"         = module.flb.files["parsers.yaml"]
    "enterprise_hello.lua" = module.flb.files["lua/enterprise_hello.lua"]
  }
  depends_on = [kubernetes_namespace_v1.this]
}

resource "helm_release" "datadog" {
  name             = local.release
  namespace        = local.dd_ns
  repository       = var.charts.datadog_repository
  chart            = "datadog"
  version          = var.charts.datadog_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 900
  max_history      = 5
  values           = local.datadog_values
  # adds the dsv-fetch-install init container (the chart has no hook for extra init containers); POSIX sh + awk on
  # the deploy agent. Relative path: the helm provider runs it from the root module's directory.
  postrender = {
    binary_path = "/bin/sh"
    args        = ["${path.module}/postrender/dsv-fetch-init.sh", "--image", var.dsv.fetch_image, "--expect", tostring(local.backend_workloads)]
  }
  depends_on = [kubernetes_namespace_v1.this]

  lifecycle {
    precondition {
      condition     = local.agent_version != null && can(regex("^7\\.[0-9]+\\.[0-9]+$", coalesce(local.agent_version, "unset")))
      error_message = "The fleet policy has no Datadog Agent version: set agent.version (7.x.y, the single pin of versions.yaml images.datadog_agent) in the fleet policy. There is no built-in fallback."
    }
    precondition {
      condition     = !(local.op_mode && local.agent_logs) || var.op_worker.enabled || var.op_logs_url != null
      error_message = "log_pipeline = observability_pipelines with Agent log collection needs op_logs_url (transport contract aggregator.agent_logs_url) or op_worker.enabled."
    }
    precondition {
      condition     = length(var.cluster_checks) == 0 || var.features.cluster_checks_runner
      error_message = "cluster_checks (e.g. DBM) need features.cluster_checks_runner = true: only the runners carry the cluster-checks identity (DSV DB passwords, Entra database login)."
    }
  }
}

resource "helm_release" "fluent_bit" {
  count            = local.fluent_bit_on ? 1 : 0
  name             = "fluent-bit"
  namespace        = local.fb_ns
  repository       = var.charts.fluent_repository
  chart            = "fluent-bit"
  version          = var.charts.fluent_bit_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600
  max_history      = 5
  values           = [yamlencode(local.fluent_bit_values)]
  depends_on       = [kubernetes_config_map_v1.fluent_bit]
}

# ------------------------------------------------------------------ optional Observability Pipelines Worker on AKS
locals {
  # chart-managed keys (pipeline id, site, API key, data dir, listen addresses) are not overridable through env
  opw_reserved  = ["DD_OP_PIPELINE_ID", "DD_SITE", "DD_API_KEY", "DD_OP_DATA_DIR", "DD_OP_DATA_DIR_BASE", "DD_OP_API_ENABLED", "DD_OP_API_ADDRESS", "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS", "DD_OP_SOURCE_FLUENT_ADDRESS", "DD_OP_TAGS", "DD_OP_LOG_FORMAT"]
  opw_extra_env = { for k, v in var.op_worker.env : k => v if !contains(local.opw_reserved, k) }
  opw_secrets   = merge({ for k, v in var.op_worker.secret_env : k => v if !contains(local.opw_reserved, k) }, { DD_API_KEY = var.dsv.api_key_ref })
  opw_values = {
    image = { tag = var.op_worker.image_tag }
    datadog = {
      # the chart Secret holds only the reference; the real values come from the dsv-fetch env file below
      apiKey     = "ENC[${var.dsv.api_key_ref}]"
      pipelineId = coalesce(var.op_worker.pipeline_id, "unset")
      site       = var.datadog.site
    }
    replicas = var.op_worker.replicas
    autoscaling = {
      enabled                        = var.op_worker.max_replicas > var.op_worker.replicas
      minReplicas                    = var.op_worker.replicas
      maxReplicas                    = var.op_worker.max_replicas
      targetCPUUtilizationPercentage = 70
    }
    podDisruptionBudget = { enabled = true, minAvailable = 1 }
    resources = {
      requests = { cpu = var.op_worker.cpu_request, memory = var.op_worker.memory_request }
      limits   = { memory = var.op_worker.memory_limit }
    }
    # DSV values (API key, e.g. the Event Hubs SASL password) from a dsv-fetch dotenv file on an in-memory emptyDir,
    # exported by the start command (the Worker image has /bin/sh; verified with 2.22.0) - no Kubernetes Secret
    serviceAccount = { create = true, annotations = local.wi_annotations }
    podLabels      = local.wi_labels
    initContainers = [{
      name            = "dsv-fetch"
      image           = var.dsv.fetch_image
      args            = concat(["init", "--out", "/dsv-secrets", "--format", "dotenv", "--dotenv-name", "opw.env"], flatten([for k in sort(keys(local.opw_secrets)) : ["--map", "${k}=${local.opw_secrets[k]}"]]))
      env             = local.dsv_env
      resources       = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "64Mi" } }
      securityContext = local.fetch_security_context
      volumeMounts    = [{ name = "dsv-secrets", mountPath = "/dsv-secrets" }]
    }]
    command           = ["/bin/sh", "-c", "set -a && . /dsv-secrets/opw.env && set +a && exec /usr/bin/observability-pipelines-worker \"$@\"", "opw"]
    args              = ["run"]
    extraVolumes      = [{ name = "dsv-secrets", emptyDir = { medium = "Memory", sizeLimit = "1Mi" } }]
    extraVolumeMounts = [{ name = "dsv-secrets", mountPath = "/dsv-secrets", readOnly = true }]
    env = concat([
      { name = "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS", value = "0.0.0.0:8282" },
      { name = "DD_OP_SOURCE_FLUENT_ADDRESS", value = "0.0.0.0:24224" },
      { name = "DD_OP_API_ENABLED", value = "true" },
      { name = "DD_OP_API_ADDRESS", value = "0.0.0.0:8686" },
      { name = "DD_OP_TAGS", value = "env:${var.datadog.env},kube_cluster_name:${var.cluster_name}" },
      { name = "DD_OP_LOG_FORMAT", value = "json" },
      ],
      [for k in sort(keys(local.opw_extra_env)) : { name = k, value = local.opw_extra_env[k] }],
    )
    service = {
      enabled = true
      type    = "ClusterIP"
      ports = [
        { name = "datadog-agent", protocol = "TCP", port = 8282, targetPort = 8282 },
        { name = "fluent", protocol = "TCP", port = 24224, targetPort = 24224 },
      ]
    }
    # disk buffers survive restarts (one volume per replica)
    persistence = { enabled = true, size = var.op_worker.persistence_size, storageClassName = var.op_worker.storage_class }
  }
}

resource "kubernetes_namespace_v1" "op_worker" {
  count = var.op_worker.enabled && var.namespaces.create ? 1 : 0
  metadata {
    name   = var.op_worker.namespace
    labels = { "app.kubernetes.io/managed-by" = "terraform", "observability/component" = "pipeline" }
  }
}

resource "helm_release" "op_worker" {
  count            = var.op_worker.enabled ? 1 : 0
  name             = "opw"
  namespace        = var.op_worker.namespace
  repository       = var.charts.datadog_repository
  chart            = "observability-pipelines-worker"
  version          = var.op_worker.chart_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600
  max_history      = 5
  values           = [yamlencode(local.opw_values)]
  depends_on       = [kubernetes_namespace_v1.op_worker]
}
