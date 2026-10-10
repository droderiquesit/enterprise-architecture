# Datadog Agent (Helm chart, DaemonSet + Cluster Agent + cluster-checks runners) on an EXISTING cluster - the fleet
# collector of the node: metrics, APM (Single Step Instrumentation of the Datadog libraries, profiler), OTLP for
# otel-mode workloads, DBM cluster checks and, with the fleet policy defaults (log_pipeline = observability_pipelines,
# logs.node_collector = agent), container logs shipped to the Observability Pipelines Worker. One log collector per
# node: the Fluent Bit DaemonSet is installed only when the policy selects it (node_collector = fluent_bit or
# log_pipeline = fluent_bit_direct), and then the Agent's log collection is off (README-transport.md).
# Secrets (ADR-0001 section 14): nothing secret passes through Terraform. Default api_key.mode = dsv_secret_backend:
# the Agents resolve api_key ENC[dsv://...] with dsv-fetch agent-backend (workload identity -> Delinea DSV), and the
# Fluent Bit DaemonSet gets its key from a dsv-fetch init container (env-yaml file on an in-memory emptyDir).
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

  dsv_mode      = var.api_key.mode == "dsv_secret_backend"
  script_source = coalesce(var.dsv.script_source, "${path.module}/../../images/dsv-fetch/dsv_fetch.py")
  dsv_base_url  = coalesce(var.dsv.base_url, "https://${coalesce(var.dsv.tenant, "unset")}.secretsvaultcloud.${coalesce(var.dsv.tld, "com")}/v1")
  dsv_env = concat(
    var.dsv.tenant == null ? [] : [{ name = "DSV_TENANT", value = var.dsv.tenant }],
    var.dsv.tld == null ? [] : [{ name = "DSV_TLD", value = var.dsv.tld }],
    [
      { name = "DSV_BASE_URL", value = local.dsv_base_url },
      { name = "DSV_AUTH", value = "azure" },
      { name = "DSV_TIMEOUT_SECONDS", value = "10" },
    ],
  )
  wi_labels      = { "azure.workload.identity/use" = "true" }
  wi_annotations = var.dsv.identity_client_id == null ? {} : { "azure.workload.identity/client-id" = var.dsv.identity_client_id }
  fetch_cm       = "dsv-fetch"
  # ConfigMap file mode 0500 (decimal 320): owner (root in the Agent containers) read+execute, no group/other -
  # the Datadog Agent refuses a secret_backend_command with group/other rights.
  backend_volume = { name = "dsv-fetch", configMap = { name = local.fetch_cm, defaultMode = 320, items = [{ key = "dsv-fetch", path = "dsv-fetch" }] } }
  backend_mount  = { name = "dsv-fetch", mountPath = "/opt/dsv-fetch", readOnly = true }

  # Agent log shipping to the Observability Pipelines Worker (Datadog Agent source) - Datadog-documented env
  agent_log_env = local.agent_logs && local.op_mode ? [
    { name = "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED", value = "true" },
    { name = "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL", value = local.op_logs_url },
  ] : []

  # trace-agent drops health-probe resources (fleet policy apm.ignore_resources)
  agent_tag = coalesce(var.charts.agent_tag, try(module.fleet.agent.version, null), "7.84.2")
  apm_ignore_env = length(module.fleet.agent_apm_ignore_resources) == 0 ? [] : [
    { name = "DD_APM_IGNORE_RESOURCES", value = join(",", module.fleet.agent_apm_ignore_resources) },
  ]

  release   = "datadog"
  dd_ns     = var.namespaces.datadog
  fb_ns     = var.namespaces.fluent_bit
  all_tags  = module.tags.tags
  dd_tags   = module.tags.dd_tags_list
  secret_ns = toset([local.dd_ns, local.fb_ns])

  kubelet = {
    aks_rotation = {}
    aks_hostca = {
      host       = { valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } }
      hostCAPath = "/etc/kubernetes/certs/kubeletserver.crt"
    }
    insecure = { tlsVerify = false }
  }[var.features.kubelet_tls_mode]

  datadog_values = {
    datadog = merge({
      site        = var.datadog.site
      clusterName = var.cluster_name
      tags        = local.dd_tags
      # one log collector per node: the Agent (-> Observability Pipelines Worker) or the Fluent Bit DaemonSet
      logs = { enabled = local.agent_logs, containerCollectAll = local.agent_logs }
      # the collectors' own namespaces are never collected (no feedback loops / duplicates)
      containerExcludeLogs = local.agent_logs ? join(" ", [for ns in var.fluent_bit.exclude_namespaces : "kube_namespace:${ns}"]) : null
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
      otlp = {
        receiver = {
          protocols = {
            grpc = { enabled = true, endpoint = "0.0.0.0:4317", useHostPort = true }
            http = { enabled = true, endpoint = "0.0.0.0:4318", useHostPort = true }
          }
        }
        logs = { enabled = false }
      }
      processAgent  = { processCollection = var.features.process_collection || try(local.agent_cfg.process_collection, false), containerCollection = true }
      clusterChecks = { enabled = true }
      # chart 3.25x bundles the Datadog Operator sub-chart and enables system-probe service discovery
      # by default for Agent >= 7.78; both are opt-in here to keep the footprint minimal
      operator  = { enabled = var.features.operator_subchart }
      discovery = { enabled = var.features.service_discovery }
      }, length(local.kubelet) > 0 ? { kubelet = local.kubelet } : {},
      # dsv mode: the chart-created Secret holds only the ENC[] reference (not a secret); existing: synced Secret
      jsondecode(local.dsv_mode ? jsonencode({
        apiKey = "ENC[${var.dsv.api_key_ref}]"
        secretBackend = {
          command   = "/opt/dsv-fetch/dsv-fetch"
          arguments = "agent-backend"
          timeout   = 30
        }
        env = concat(local.dsv_env, local.agent_log_env, local.apm_ignore_env)
      }) : jsonencode({ apiKeyExistingSecret = var.api_key.secret_name, env = concat(local.agent_log_env, local.apm_ignore_env) })),
    )
    # Remote Configuration (Fleet Automation, APM sampling / SSI policies); preferred top-level key of the chart
    remoteConfiguration = { enabled = try(local.agent_cfg.remote_configuration, true) }
    providers           = { aks = { enabled = var.features.is_aks } }
    agents = merge({
      image = { tag = local.agent_tag }
      containers = {
        agent        = { resources = { requests = { cpu = var.resources.agent_cpu_request, memory = var.resources.agent_memory_request }, limits = { memory = var.resources.agent_memory_limit } } }
        traceAgent   = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.trace_memory_limit } } }
        processAgent = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.process_memory_limit } } }
        systemProbe  = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.process_memory_limit } } }
      }
      }, jsondecode(local.dsv_mode ? jsonencode({
        # workload identity for dsv-fetch (service account "datadog", shared with the cluster-checks runners)
        rbac             = { serviceAccountAnnotations = local.wi_annotations }
        additionalLabels = local.wi_labels
        volumes          = [local.backend_volume]
        volumeMounts     = [local.backend_mount]
    }) : "{}"))
    clusterAgent = {
      enabled   = true
      replicas  = var.features.cluster_agent_replicas
      image     = { tag = local.agent_tag }
      resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = var.resources.cluster_agent_memory } }
      confd     = var.cluster_checks
      # No Python in the Cluster Agent image -> it cannot run dsv-fetch. These entries come after the chart's own
      # DD_API_KEY / DD_SECRET_BACKEND_COMMAND (helm template verified) and the last duplicate env entry wins:
      #   cluster_agent_secret_name set : DD_API_KEY from that (dsv-k8s syncer managed) Secret
      #   unset                         : secret backend disabled for the DCA so the ENC[] string cannot block its
      #                                   start; DCA features that need a valid key stay unauthenticated (README)
      env = concat(local.ssi_dca_env, jsondecode(!local.dsv_mode ? "[]" : (var.api_key.cluster_agent_secret_name != null ? jsonencode([
        { name = "DD_API_KEY", valueFrom = { secretKeyRef = { name = var.api_key.cluster_agent_secret_name, key = "api-key" } } },
        ]) : jsonencode([
        { name = "DD_SECRET_BACKEND_COMMAND", value = "" },
      ]))))
    }
    clusterChecksRunner = {
      enabled   = var.features.cluster_checks_runner
      replicas  = 1
      image     = { tag = local.agent_tag }
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = var.resources.runner_memory_limit } }
      env = concat(
        local.dsv_mode ? local.dsv_env : [],
        [for k in sort(keys(var.cluster_check_env)) : {
          name      = k
          valueFrom = { secretKeyRef = { name = var.cluster_check_env[k].secret_name, key = var.cluster_check_env[k].secret_key } }
        }],
      )
      additionalLabels = local.dsv_mode ? local.wi_labels : {}
      # dedicated service account "datadog-cluster-checks" (federated with the same identity)
      rbac         = { dedicated = local.dsv_mode, serviceAccountAnnotations = local.dsv_mode ? local.wi_annotations : {} }
      volumes      = local.dsv_mode ? [local.backend_volume] : []
      volumeMounts = local.dsv_mode ? [local.backend_mount] : []
    }
  }
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
  fluent_bit_values = {
    kind              = "DaemonSet"
    image             = { repository = var.charts.fluent_bit_image, tag = var.charts.fluent_bit_tag }
    existingConfigMap = local.flb_cm_name
    args              = ["--workdir=/fluent-bit/etc", "--config=/fluent-bit/etc/eh/fluent-bit.yaml"]
    env = concat(
      # must precede FLB_OTLP_HOST=$(DD_AGENT_HOST) (Kubernetes dependent env expansion)
      [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }],
      [for k in sort(keys(module.flb.env)) : { name = k, value = module.flb.env[k] }],
      # existing mode only: the key from the synced Secret (the included env file is then an empty placeholder)
      local.dsv_mode || local.op_mode ? [] : [{ name = "DD_API_KEY", valueFrom = { secretKeyRef = { name = var.api_key.secret_name, key = "api-key" } } }],
    )
    # dsv mode: dsv-fetch writes /dsv-secrets/fluentbit-env.yaml (DD_API_KEY) from DSV with workload identity
    # (observability_pipelines: no key on the edge -> no dsv-fetch)
    initContainers = local.dsv_mode && !local.op_mode ? [{
      name  = "dsv-fetch"
      image = var.dsv.fetch_image
      args  = ["init", "--out", "/dsv-secrets", "--format", "env-yaml", "--env-yaml-name", "fluentbit-env.yaml", "--map", "DD_API_KEY=${var.dsv.api_key_ref}"]
      env   = local.dsv_env
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
      securityContext = { runAsNonRoot = true, allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
      volumeMounts    = [{ name = "dsv-secrets", mountPath = "/dsv-secrets" }]
    }] : []
    podLabels      = local.dsv_mode && !local.op_mode ? local.wi_labels : {}
    serviceAccount = { create = true, annotations = local.dsv_mode && !local.op_mode ? local.wi_annotations : {} }
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
      jsondecode(local.dsv_mode || local.op_mode ? jsonencode({ name = "dsv-secrets", emptyDir = { medium = "Memory", sizeLimit = "1Mi" } }) : jsonencode({ name = "dsv-secrets", configMap = { name = "fluent-bit-env-placeholder" } })),
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
    resources   = { requests = { cpu = var.resources.fluent_bit_cpu, memory = var.resources.fluent_bit_memory }, limits = { memory = var.resources.fluent_bit_mem_limit } }
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
  for_each = var.namespaces.create ? local.secret_ns : toset([])
  metadata {
    name   = each.value
    labels = { "app.kubernetes.io/managed-by" = "terraform", "observability/component" = "collection" }
  }
}

# Agent secret backend: the stdlib dsv-fetch script (observability/images/dsv-fetch) as a ConfigMap, mounted 0500.
resource "kubernetes_config_map_v1" "dsv_fetch" {
  count = local.dsv_mode ? 1 : 0
  metadata {
    name      = local.fetch_cm
    namespace = local.dd_ns
  }
  data       = { "dsv-fetch" = file(local.script_source) }
  depends_on = [kubernetes_namespace_v1.this]
}

# existing mode: Fluent Bit's config always includes /dsv-secrets/fluentbit-env.yaml; an empty env section lets
# ${DD_API_KEY} fall back to the container env from the synced Secret (verified with Fluent Bit 5.1.3).
resource "kubernetes_config_map_v1" "fluent_bit_env_placeholder" {
  count = local.fluent_bit_on && !local.dsv_mode && !local.op_mode ? 1 : 0
  metadata {
    name      = "fluent-bit-env-placeholder"
    namespace = local.fb_ns
  }
  data       = { "fluentbit-env.yaml" = "# DD_API_KEY comes from the container env (api_key.mode = existing)\nenv: {}\n" }
  depends_on = [kubernetes_namespace_v1.this]
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
  values           = [yamlencode(local.datadog_values)]
  depends_on       = [kubernetes_config_map_v1.dsv_fetch, kubernetes_namespace_v1.this]

  lifecycle {
    precondition {
      condition     = !local.dsv_mode || var.dsv.identity_client_id != null
      error_message = "api_key.mode = dsv_secret_backend needs dsv.identity_client_id (workload identity of the service account datadog)."
    }
    precondition {
      condition     = !(local.op_mode && local.agent_logs) || var.op_worker.enabled || var.op_logs_url != null
      error_message = "log_pipeline = observability_pipelines with Agent log collection needs op_logs_url (transport contract aggregator.agent_logs_url) or op_worker.enabled."
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
  depends_on       = [kubernetes_config_map_v1.fluent_bit, kubernetes_config_map_v1.fluent_bit_env_placeholder]

  lifecycle {
    precondition {
      condition     = !local.dsv_mode || (var.dsv.fetch_image != null && var.dsv.identity_client_id != null)
      error_message = "api_key.mode = dsv_secret_backend needs dsv.fetch_image (dsv-fetch init container) and dsv.identity_client_id."
    }
  }
}

# ------------------------------------------------------------------ optional Observability Pipelines Worker on AKS
locals {
  # chart-managed keys (pipeline id, site, API key, data dir, listen addresses) are not overridable through env
  opw_extra_env = { for k, v in var.op_worker.env : k => v if !contains(["DD_OP_PIPELINE_ID", "DD_SITE", "DD_API_KEY", "DD_OP_DATA_DIR", "DD_OP_DATA_DIR_BASE", "DD_OP_API_ENABLED", "DD_OP_API_ADDRESS", "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS", "DD_OP_SOURCE_FLUENT_ADDRESS", "DD_OP_TAGS", "DD_OP_LOG_FORMAT"], k) }
  opw_values = {
    image = { tag = var.op_worker.image_tag }
    datadog = {
      apiKeyExistingSecret = var.op_worker.api_key_secret_name
      pipelineId           = coalesce(var.op_worker.pipeline_id, "unset")
      site                 = var.datadog.site
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
    env = concat([
      { name = "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS", value = "0.0.0.0:8282" },
      { name = "DD_OP_SOURCE_FLUENT_ADDRESS", value = "0.0.0.0:24224" },
      { name = "DD_OP_API_ENABLED", value = "true" },
      { name = "DD_OP_API_ADDRESS", value = "0.0.0.0:8686" },
      { name = "DD_OP_TAGS", value = "env:${var.datadog.env},kube_cluster_name:${var.cluster_name}" },
      { name = "DD_OP_LOG_FORMAT", value = "json" },
      ],
      [for k in sort(keys(local.opw_extra_env)) : { name = k, value = local.opw_extra_env[k] }],
      [for k in sort(keys(var.op_worker.secret_env)) : { name = k, valueFrom = { secretKeyRef = { name = var.op_worker.secret_env[k].secret_name, key = var.op_worker.secret_env[k].key } } }],
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
