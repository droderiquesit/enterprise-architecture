# Datadog Agent (Helm chart, DaemonSet + Cluster Agent + cluster-checks runners) and the Fluent Bit
# DaemonSet on an EXISTING cluster. Fluent Bit is the only container-log collector: the Agent runs with
# datadog.logs.enabled=false and containerCollectAll=false (README-transport.md).
locals {
  release   = "datadog"
  dd_ns     = var.namespaces.datadog
  fb_ns     = var.namespaces.fluent_bit
  all_tags  = merge({ env = var.datadog.env }, var.datadog.extra_tags)
  dd_tags   = [for k in sort(keys(local.all_tags)) : "${k}:${local.all_tags[k]}"]
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
      site                 = var.datadog.site
      clusterName          = var.cluster_name
      apiKeyExistingSecret = var.api_key.secret_name
      tags                 = local.dd_tags
      # Fluent Bit owns container logs (no duplicates)
      logs = { enabled = false, containerCollectAll = false }
      apm  = { socketEnabled = var.features.apm, portEnabled = var.features.apm }
      otlp = {
        receiver = {
          protocols = {
            grpc = { enabled = true, endpoint = "0.0.0.0:4317", useHostPort = true }
            http = { enabled = true, endpoint = "0.0.0.0:4318", useHostPort = true }
          }
        }
        logs = { enabled = false }
      }
      processAgent  = { processCollection = var.features.process_collection, containerCollection = true }
      clusterChecks = { enabled = true }
      # chart 3.25x bundles the Datadog Operator sub-chart and enables system-probe service discovery
      # by default for Agent >= 7.78; both are opt-in here to keep the footprint minimal
      operator  = { enabled = var.features.operator_subchart }
      discovery = { enabled = var.features.service_discovery }
      }, length(local.kubelet) > 0 ? { kubelet = local.kubelet } : {}
    )
    providers = { aks = { enabled = var.features.is_aks } }
    agents = {
      image = { tag = var.charts.agent_tag }
      containers = {
        agent        = { resources = { requests = { cpu = var.resources.agent_cpu_request, memory = var.resources.agent_memory_request }, limits = { memory = var.resources.agent_memory_limit } } }
        traceAgent   = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.trace_memory_limit } } }
        processAgent = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.process_memory_limit } } }
        systemProbe  = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = var.resources.process_memory_limit } } }
      }
    }
    clusterAgent = {
      enabled   = true
      replicas  = var.features.cluster_agent_replicas
      image     = { tag = var.charts.agent_tag }
      resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = var.resources.cluster_agent_memory } }
      confd     = var.cluster_checks
    }
    clusterChecksRunner = {
      enabled   = var.features.cluster_checks_runner
      replicas  = 1
      image     = { tag = var.charts.agent_tag }
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = var.resources.runner_memory_limit } }
      env = [for k in sort(keys(var.cluster_check_env)) : {
        name      = k
        valueFrom = { secretKeyRef = { name = var.cluster_check_env[k].secret_name, key = var.cluster_check_env[k].secret_key } }
      }]
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
}

locals {
  flb_cm_name = "fluent-bit-eh-config"
  fluent_bit_values = {
    kind              = "DaemonSet"
    image             = { repository = var.charts.fluent_bit_image, tag = var.charts.fluent_bit_tag }
    existingConfigMap = local.flb_cm_name
    args              = ["--workdir=/fluent-bit/etc", "--config=/fluent-bit/etc/eh/fluent-bit.yaml"]
    env = concat(
      # must precede FLB_OTLP_HOST=$(DD_AGENT_HOST) (Kubernetes dependent env expansion)
      [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }],
      [for k in sort(keys(module.flb.env)) : { name = k, value = module.flb.env[k] }],
      [{ name = "DD_API_KEY", valueFrom = { secretKeyRef = { name = var.api_key.secret_name, key = "api-key" } } }],
    )
    extraVolumes = [{
      name = "eh-config"
      configMap = {
        name = local.flb_cm_name
        items = [
          { key = "fluent-bit.yaml", path = "fluent-bit.yaml" },
          { key = "parsers.yaml", path = "parsers.yaml" },
          { key = "enterprise_hello.lua", path = "lua/enterprise_hello.lua" },
        ]
      }
    }]
    extraVolumeMounts = [{ name = "eh-config", mountPath = "/fluent-bit/etc/eh", readOnly = true }]
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
      "checksum/eh-config" = module.flb.files_sha256
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

resource "kubernetes_secret_v1" "api_key" {
  for_each = var.api_key.mode == "write_only" ? local.secret_ns : toset([])
  metadata {
    name      = var.api_key.secret_name
    namespace = each.value
  }
  type             = "Opaque"
  data_wo          = { "api-key" = var.api_key_wo }
  data_wo_revision = var.api_key.revision

  depends_on = [kubernetes_namespace_v1.this]

  lifecycle {
    precondition {
      condition     = var.api_key_wo != null
      error_message = "api_key.mode = write_only requires the ephemeral input api_key_wo."
    }
  }
}

resource "kubernetes_config_map_v1" "fluent_bit" {
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
  depends_on       = [kubernetes_secret_v1.api_key, kubernetes_namespace_v1.this]
}

resource "helm_release" "fluent_bit" {
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
  depends_on       = [kubernetes_secret_v1.api_key, kubernetes_config_map_v1.fluent_bit]
}
