# Enterprise Hello core services on AKS (namespace `hello`): hello-bff, hello-orders-api, hello-catalog-api,
# hello-worker - one Helm release per workload from the repository chart applications/charts/hello-service
# (Deployment, workload identity ServiceAccount, Service, PDB, HPA, optional Ingress / NetworkPolicy). Values are rendered here from the upstream contracts (yamlencode of a typed object).
# Logs: stdout -> Fluent Bit DaemonSet (obs-kubernetes). Traces: OTLP to the node-local Datadog Agent
# (status.hostIP via the downward API). Secrets (ADR-0001 §14): secret settings are env values holding Delinea DSV
# references (chart secretEnv); the app resolves them at start-up with its AKS workload identity. Fallback
# settings.secrets_mode = synced: the chart reads a Secret maintained by the Delinea dsv-k8s syncer. No Key Vault.
module "meta" {
  source = "../modules/service-meta"
}

locals {
  ids   = var.foundation_identity.identities
  meta  = module.meta.services
  ns    = var.settings.namespace
  apps  = { for k, a in var.settings.apps : k => a if a.enabled }
  http  = { for k, a in local.apps : k => a if k != "hello-worker" }
  port  = { for k in keys(local.apps) : k => k == "hello-worker" ? 8081 : 8080 }
  wi    = var.platform_aks.workload_identities
  redis = var.platform_db_redis

  svc_url = { for k in keys(local.http) : k => "http://${k}.${local.ns}.svc.cluster.local" }

  service_env = {
    "hello-bff" = merge(
      {
        CATALOG_API_URL      = local.svc_url["hello-catalog-api"]
        ORDERS_API_URL       = local.svc_url["hello-orders-api"]
        ADAPTERS_JSON        = jsonencode(var.settings.adapters)
        CORS_ALLOWED_ORIGINS = join(",", var.settings.cors_allowed_origins)
        AUTH_MODE            = var.settings.auth_mode
      },
      var.settings.inventory_api_url == null ? {} : { INVENTORY_API_URL = var.settings.inventory_api_url },
    )
    "hello-orders-api" = {
      SQL_CONNECTION_STRING    = "Server=tcp:${var.platform_db_sql.server.fqdn},${var.platform_db_sql.server.port};Database=${var.platform_db_sql.databases["orders"].name};Encrypt=True"
      SQL_USE_AZURE_CREDENTIAL = "true" # token from AzureCredentialFactory (workload/managed identity); no password
      CATALOG_API_URL          = local.svc_url["hello-catalog-api"]
      MESSAGING_MODE           = "servicebus"
      SERVICEBUS_FQDN          = var.platform_messaging.fqdn
      SERVICEBUS_TOPIC         = var.platform_messaging.topic.name
    }
    "hello-catalog-api" = merge(
      {
        PG_HOST           = var.platform_db_postgresql.server.fqdn
        PG_PORT           = tostring(var.platform_db_postgresql.server.port)
        PG_DATABASE       = var.platform_db_postgresql.databases["catalog"].name
        PG_USER           = "hello-catalog-api"
        PG_AUTH           = "entra"
        CACHE_TTL_SECONDS = tostring(var.settings.redis_cache_ttl_seconds)
      },
      local.redis == null ? { REDIS_AUTH = "none" } : { REDIS_HOST = local.redis.cache.hostname, REDIS_PORT = tostring(local.redis.cache.port), REDIS_AUTH = "entra" },
    )
    "hello-worker" = {
      MESSAGING_MODE            = "servicebus"
      SERVICEBUS_FQDN           = var.platform_messaging.fqdn
      SB_TOPIC                  = var.platform_messaging.topic.name
      SB_SUBSCRIPTION           = var.platform_messaging.subscriptions["notifications"].name
      TABLE_MODE                = "memory" # platform-db-table-storage is not consumed by deploy-core-aks (see README)
      HEALTH_PORT               = "8081"
      OTEL_PYTHON_EXCLUDED_URLS = "healthz,readyz,version"
    }
  }
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.apps

  service = {
    name    = each.key
    version = local.artifact_version[local.meta[each.key].artifact]
    commit  = local.artifact_commit[local.meta[each.key].artifact]
    env     = local.env_name
    team    = local.meta[each.key].team
    owner   = local.meta[each.key].owner
    domain  = local.meta[each.key].domain
    tier    = local.meta[each.key].tier
    region  = local.location
  }
  runtime      = local.meta[each.key].runtime
  architecture = "aks"
  telemetry    = var.obs_telemetry_transport
  # Workload identity: the webhook injects AZURE_CLIENT_ID from the ServiceAccount annotation; it is set
  # explicitly as well so non-SDK code paths see the same value.
  identity_client_id = local.wi[each.key].client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = each.key != "hello-worker" ? lookup(var.foundation_identity.secrets.refs, "fault-token", null) : null
  }
  port               = local.port[each.key]
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = local.service_env[each.key]
}

resource "kubernetes_namespace_v1" "hello" {
  metadata {
    name = local.ns
    labels = {
      "app.kubernetes.io/part-of"          = "enterprise-hello"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# ---------------------------------------------------------------- Helm values (one typed object per workload)
locals {
  # Repository chart by default; the published OCI chart when settings.helm.chart_repository is set.
  chart = var.settings.helm.chart_repository == null ? {
    chart      = abspath("${path.module}/../../charts/hello-service")
    repository = null
    version    = null
    } : {
    chart      = "hello-service"
    repository = var.settings.helm.chart_repository
    version    = var.settings.helm.chart_version
  }

  # Env vars the chart renders itself from service/identity/faults/port (labels and env cannot disagree);
  # the schema rejects them in `env`.
  chart_owned_env = ["DD_AGENT_HOST", "DD_ENV", "DD_SERVICE", "DD_VERSION", "AZURE_CLIENT_ID", "FAULTS_ENABLED", "PORT", "LOG_FILE_PATH", "DSV_TENANT", "DSV_TLD", "DSV_BASE_URL", "DSV_AUTH"]
  dsv             = var.obs_telemetry_transport.secrets

  image      = { for k in keys(local.apps) : k => try(var.artifacts[local.meta[k].artifact].image, null) }
  secret_env = { for k in keys(local.apps) : k => module.env[k].secret_env }
  bff_lb     = var.settings.exposure.mode == "internal-lb"

  release_values = {
    for k, a in local.apps : k => {
      kind = k == "hello-worker" ? "worker" : "deployment"
      service = {
        name       = k
        version    = local.artifact_version[local.meta[k].artifact]
        env        = local.env_name
        partOf     = "enterprise-hello"
        team       = local.meta[k].team
        domain     = local.meta[k].domain
        tier       = local.meta[k].tier
        logsSource = module.env[k].k8s_patch_object.metadata.labels["logs.datadoghq.com/source"]
        # tag policy: every other Datadog tag -> pod annotation ad.datadoghq.com/tags
        tags = module.env[k].extra_tags_map
      }
      image = {
        repository = try(split("@", local.image[k])[0], "")
        digest     = try(split("@", local.image[k])[1], "")
        pullPolicy = "IfNotPresent"
      }
      identity = {
        clientId         = local.wi[k].client_id
        tenantId         = var.environment.tenant_id
        workloadIdentity = true
      }
      serviceAccount = { create = true, name = local.wi[k].service_account }
      port           = local.port[k]
      env            = { for n, v in module.env[k].env : n => v if !contains(local.chart_owned_env, n) && !contains(keys(local.secret_env[k]), n) }
      secretEnv      = local.secret_env[k]
      dsv = {
        tenant  = coalesce(local.dsv.tenant, "")
        tld     = coalesce(local.dsv.tld, "com")
        baseUrl = local.dsv.base_url
        auth    = coalesce(local.dsv.auth, "azure")
      }
      secretsMode = var.settings.secrets_mode
      secretsSync = { secretName = "" }
      # log collector per the fleet policy (Fluent Bit DaemonSet or the node Agent -> Observability Pipelines) and the
      # SSI admission label when the Datadog library is injected (labels/annotations only; env comes from app-env)
      telemetry = {
        agentHostFromHostIP       = true
        disableAgentLogCollection = module.env[k].log_collector != "datadog-agent"
        agentLogSource            = module.env[k].log_collector == "datadog-agent" ? module.env[k].k8s_patch_object.metadata.labels["logs.datadoghq.com/source"] : ""
        singleStepInstrumentation = module.env[k].apm.method == "ssi_kubernetes"
      }
      logFile = { enabled = false } # stdout -> Fluent Bit DaemonSet
      # Faults need FAULT_TOKEN (dsv:// reference); without it FAULTS_ENABLED stays false (chart schema rule).
      faults = { enabled = var.settings.faults_enabled && contains(keys(local.secret_env[k]), "FAULT_TOKEN") }
      resources = {
        requests = { cpu = a.cpu_request, memory = a.memory_request }
        limits   = { cpu = a.cpu_limit, memory = a.memory_limit }
      }
      autoscaling = {
        enabled                        = true
        minReplicas                    = a.min_replicas
        maxReplicas                    = min(a.max_replicas, var.settings.replica_ceiling)
        targetCPUUtilizationPercentage = a.target_cpu
      }
      podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
      k8sService = {
        type                 = k == "hello-bff" && local.bff_lb ? "LoadBalancer" : "ClusterIP"
        port                 = 80
        internalLoadBalancer = k == "hello-bff" && local.bff_lb
      }
      ingress = {
        enabled   = k == "hello-bff" && var.settings.exposure.mode == "app-routing"
        className = "webapprouting.kubernetes.azure.com"
        host      = var.settings.exposure.host == null ? "" : var.settings.exposure.host
        # existing TLS Secret (Delinea dsv-k8s syncer or cert-manager); no Key Vault certificate sync
        tls = {
          enabled    = true
          secretName = var.settings.exposure.tls_secret_name
        }
      }
      networkPolicy = {
        enabled             = var.settings.network_policy_enabled
        allowFromNamespaces = k == "hello-bff" ? ["app-routing-system"] : []
        allowFromCIDRs      = k == "hello-bff" ? var.settings.network_policy_allow_cidrs : []
      }
      topologySpread = { enabled = true, hostnameSkew = 1, zoneSpread = false }
    }
  }
}

# One release per workload: independent upgrade/rollback (`helm rollback <svc> -n hello`), atomic (a failed
# upgrade rolls back to the last good revision), waits for readiness (rollout gated by /readyz).
resource "helm_release" "app" {
  for_each = local.apps

  name             = each.key
  namespace        = kubernetes_namespace_v1.hello.metadata[0].name
  create_namespace = false
  chart            = local.chart.chart
  repository       = local.chart.repository
  version          = local.chart.version
  description      = "${each.key} ${local.release_values[each.key].service.version}"

  values = [yamlencode(local.release_values[each.key])]

  atomic          = true
  wait            = true
  wait_for_jobs   = false
  cleanup_on_fail = true
  timeout         = var.settings.helm.timeout_seconds
  max_history     = var.settings.helm.max_history
  lint            = true
  take_ownership  = var.settings.helm.take_ownership

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", coalesce(local.image[each.key], "x")))
      error_message = "${each.key}: needs a digest-pinned image in var.artifacts[${local.meta[each.key].artifact}]."
    }
  }
}

# Internal LB address of hello-bff (helm waits for the LoadBalancer ingress IP before the release succeeds).
data "kubernetes_service_v1" "bff" {
  count = local.bff_lb && contains(keys(local.http), "hello-bff") ? 1 : 0
  metadata {
    name      = "hello-bff"
    namespace = local.ns
  }
  depends_on = [helm_release.app]
}

check "artifacts_present" {
  assert {
    condition     = alltrue([for k in keys(local.apps) : can(regex("@sha256:[a-f0-9]{64}$", var.artifacts[local.meta[k].artifact].image))])
    error_message = "Every enabled app needs a digest-pinned image in var.artifacts (svc-bff, svc-orders-api, svc-catalog-api, svc-worker)."
  }
}
