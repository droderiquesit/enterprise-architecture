# Datadog Agent (Helm chart, DaemonSet + Cluster Agent + cluster-checks runners) and the Fluent Bit
# DaemonSet on an EXISTING cluster. Fluent Bit is the only container-log collector: the Agent runs with
# datadog.logs.enabled=false and containerCollectAll=false (README-transport.md).
# Secrets (ADR-0001 section 14): nothing secret passes through Terraform. Default api_key.mode = dsv_secret_backend:
# the Agents resolve api_key ENC[dsv://...] with dsv-fetch agent-backend (workload identity -> Delinea DSV), and the
# Fluent Bit DaemonSet gets its key from a dsv-fetch init container (env-yaml file on an in-memory emptyDir).
locals {
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
      site        = var.datadog.site
      clusterName = var.cluster_name
      tags        = local.dd_tags
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
      }, length(local.kubelet) > 0 ? { kubelet = local.kubelet } : {},
      # dsv mode: the chart-created Secret holds only the ENC[] reference (not a secret); existing: synced Secret
      jsondecode(local.dsv_mode ? jsonencode({
        apiKey = "ENC[${var.dsv.api_key_ref}]"
        secretBackend = {
          command   = "/opt/dsv-fetch/dsv-fetch"
          arguments = "agent-backend"
          timeout   = 30
        }
        env = local.dsv_env
      }) : jsonencode({ apiKeyExistingSecret = var.api_key.secret_name })),
    )
    providers = { aks = { enabled = var.features.is_aks } }
    agents = merge({
      image = { tag = var.charts.agent_tag }
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
      image     = { tag = var.charts.agent_tag }
      resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = var.resources.cluster_agent_memory } }
      confd     = var.cluster_checks
      # No Python in the Cluster Agent image -> it cannot run dsv-fetch. These entries come after the chart's own
      # DD_API_KEY / DD_SECRET_BACKEND_COMMAND (helm template verified) and the last duplicate env entry wins:
      #   cluster_agent_secret_name set : DD_API_KEY from that (dsv-k8s syncer managed) Secret
      #   unset                         : secret backend disabled for the DCA so the ENC[] string cannot block its
      #                                   start; DCA features that need a valid key stay unauthenticated (README)
      env = jsondecode(!local.dsv_mode ? "[]" : (var.api_key.cluster_agent_secret_name != null ? jsonencode([
        { name = "DD_API_KEY", valueFrom = { secretKeyRef = { name = var.api_key.cluster_agent_secret_name, key = "api-key" } } },
        ]) : jsonencode([
        { name = "DD_SECRET_BACKEND_COMMAND", value = "" },
      ])))
    }
    clusterChecksRunner = {
      enabled   = var.features.cluster_checks_runner
      replicas  = 1
      image     = { tag = var.charts.agent_tag }
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
      local.dsv_mode ? [] : [{ name = "DD_API_KEY", valueFrom = { secretKeyRef = { name = var.api_key.secret_name, key = "api-key" } } }],
    )
    # dsv mode: dsv-fetch writes /dsv-secrets/fluentbit-env.yaml (DD_API_KEY) from DSV with workload identity
    initContainers = local.dsv_mode ? [{
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
    podLabels      = local.dsv_mode ? local.wi_labels : {}
    serviceAccount = { create = true, annotations = local.dsv_mode ? local.wi_annotations : {} }
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
      jsondecode(local.dsv_mode ? jsonencode({ name = "dsv-secrets", emptyDir = { medium = "Memory", sizeLimit = "1Mi" } }) : jsonencode({ name = "dsv-secrets", configMap = { name = "fluent-bit-env-placeholder" } })),
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
  count = local.dsv_mode ? 0 : 1
  metadata {
    name      = "fluent-bit-env-placeholder"
    namespace = local.fb_ns
  }
  data       = { "fluentbit-env.yaml" = "# DD_API_KEY comes from the container env (api_key.mode = existing)\nenv: {}\n" }
  depends_on = [kubernetes_namespace_v1.this]
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
  depends_on       = [kubernetes_config_map_v1.dsv_fetch, kubernetes_namespace_v1.this]

  lifecycle {
    precondition {
      condition     = !local.dsv_mode || var.dsv.identity_client_id != null
      error_message = "api_key.mode = dsv_secret_backend needs dsv.identity_client_id (workload identity of the service account datadog)."
    }
  }
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
  depends_on       = [kubernetes_config_map_v1.fluent_bit, kubernetes_config_map_v1.fluent_bit_env_placeholder]

  lifecycle {
    precondition {
      condition     = !local.dsv_mode || (var.dsv.fetch_image != null && var.dsv.identity_client_id != null)
      error_message = "api_key.mode = dsv_secret_backend needs dsv.fetch_image (dsv-fetch init container) and dsv.identity_client_id."
    }
  }
}
