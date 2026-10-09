# Enterprise Hello core services on AKS (namespace `hello`): hello-bff, hello-orders-api, hello-catalog-api,
# hello-worker as Deployments with workload identity ServiceAccounts, Services, PDBs and HPAs.
# Logs: stdout -> Fluent Bit DaemonSet (obs-kubernetes). Traces: OTLP to the node-local Datadog Agent
# (status.hostIP via the downward API). Secrets: Key Vault via the Secrets Store CSI driver add-on
# (SecretProviderClass with the workload identity) synced to a Kubernetes Secret.
module "meta" {
  source = "../modules/service-meta"
}

locals {
  ids     = var.foundation_identity.identities
  meta    = module.meta.services
  ns      = var.settings.namespace
  apps    = { for k, a in var.settings.apps : k => a if a.enabled }
  http    = { for k, a in local.apps : k => a if k != "hello-worker" }
  port    = { for k in keys(local.apps) : k => k == "hello-worker" ? 8081 : 8080 }
  wi      = var.platform_aks.workload_identities
  csi     = var.platform_aks.key_vault_secrets_provider != null
  kv_name = regex("^https://([^.]+)\\.", var.foundation_identity.key_vault_uri)[0]
  redis   = var.platform_db_redis

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
    enabled         = var.settings.faults_enabled
    token_secret_id = local.csi && each.key != "hello-worker" ? lookup(var.foundation_identity.secret_ids, "fault-token", null) : null
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

resource "kubernetes_service_account_v1" "app" {
  for_each = local.apps
  metadata {
    name      = local.wi[each.key].service_account
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = local.wi[each.key].client_id
      "azure.workload.identity/tenant-id" = var.environment.tenant_id
    }
    labels = { "app.kubernetes.io/name" = each.key }
  }
  automount_service_account_token = false
}

# Key Vault secrets (FAULT_TOKEN) through the Secrets Store CSI driver add-on, authenticated with the
# pod's workload identity; synced into the Kubernetes Secret "<svc>-kv" while a pod mounts the volume.
resource "kubernetes_manifest" "secret_provider" {
  for_each = { for k in keys(local.apps) : k => module.env[k].secret_env if local.csi && length(module.env[k].secret_env) > 0 }
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata   = { name = "${each.key}-kv", namespace = local.ns }
    spec = {
      provider = "azure"
      parameters = {
        usePodIdentity = "false"
        clientID       = local.wi[each.key].client_id
        keyvaultName   = local.kv_name
        tenantId       = var.environment.tenant_id
        objects = yamlencode({ array = [for name, id in each.value : yamlencode({
          objectName  = element(split("/", id), length(split("/", id)) - 1)
          objectType  = "secret"
          objectAlias = name
        })] })
      }
      secretObjects = [{
        secretName = "${each.key}-kv"
        type       = "Opaque"
        data       = [for name in sort(keys(each.value)) : { objectName = name, key = name }]
      }]
    }
  }
  depends_on = [kubernetes_namespace_v1.hello]
}

resource "kubernetes_deployment_v1" "app" {
  for_each         = local.apps
  wait_for_rollout = true

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
    labels    = merge(module.env[each.key].k8s_patch_object.metadata.labels, { "app.kubernetes.io/name" = each.key, "app.kubernetes.io/part-of" = "enterprise-hello" })
  }

  spec {
    replicas               = each.value.min_replicas
    revision_history_limit = 5
    selector {
      match_labels = { "app.kubernetes.io/name" = each.key }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
    template {
      metadata {
        labels = merge(module.env[each.key].k8s_patch_object.spec.template.metadata.labels, {
          "app.kubernetes.io/name"      = each.key
          "app.kubernetes.io/version"   = local.artifact_version[local.meta[each.key].artifact]
          "azure.workload.identity/use" = "true"
        })
        annotations = {
          # Logs are collected by the Fluent Bit DaemonSet only; the Datadog Agent must not ship them too.
          "ad.datadoghq.com/${each.key}.logs" = "[]"
        }
      }
      spec {
        service_account_name             = kubernetes_service_account_v1.app[each.key].metadata[0].name
        automount_service_account_token  = true # projected token for workload identity
        termination_grace_period_seconds = 30
        security_context {
          # Images run as a numeric non-root user (.NET chiseled: 1654); no fixed uid imposed here.
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { "app.kubernetes.io/name" = each.key }
          }
        }

        container {
          name              = each.key
          image             = try(var.artifacts[local.meta[each.key].artifact].image, null)
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = local.port[each.key]
          }

          # DD_AGENT_HOST must precede OTEL_EXPORTER_OTLP_ENDPOINT, which references $(DD_AGENT_HOST).
          env {
            name = "DD_AGENT_HOST"
            value_from {
              field_ref {
                field_path = "status.hostIP"
              }
            }
          }
          dynamic "env" {
            for_each = sort(keys(module.env[each.key].env))
            content {
              name  = env.value
              value = module.env[each.key].env[env.value]
            }
          }
          dynamic "env" {
            for_each = local.csi ? sort(keys(module.env[each.key].secret_env)) : []
            content {
              name = env.value
              value_from {
                secret_key_ref {
                  name = "${each.key}-kv"
                  key  = env.value
                }
              }
            }
          }

          resources {
            requests = { cpu = each.value.cpu_request, memory = each.value.memory_request }
            limits   = { cpu = each.value.cpu_limit, memory = each.value.memory_limit }
          }

          startup_probe {
            http_get {
              path = "/healthz"
              port = local.port[each.key]
            }
            period_seconds    = 5
            failure_threshold = 24
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.port[each.key]
            }
            period_seconds    = 15
            failure_threshold = 3
          }
          readiness_probe {
            http_get {
              path = "/readyz"
              port = local.port[each.key]
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          dynamic "volume_mount" {
            for_each = contains(keys(kubernetes_manifest.secret_provider), each.key) ? [1] : []
            content {
              name       = "kv-secrets"
              mount_path = "/mnt/secrets"
              read_only  = true
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "256Mi"
          }
        }
        dynamic "volume" {
          for_each = contains(keys(kubernetes_manifest.secret_provider), each.key) ? [1] : []
          content {
            name = "kv-secrets"
            csi {
              driver            = "secrets-store.csi.k8s.io"
              read_only         = true
              volume_attributes = { secretProviderClass = "${each.key}-kv" }
            }
          }
        }
      }
    }
  }

  # Replica count is owned by the HPA after creation.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

resource "kubernetes_service_v1" "app" {
  for_each = local.http
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
    labels    = { "app.kubernetes.io/name" = each.key }
    annotations = each.key == "hello-bff" && var.settings.exposure.mode == "internal-lb" ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }
  spec {
    type     = each.key == "hello-bff" && var.settings.exposure.mode == "internal-lb" ? "LoadBalancer" : "ClusterIP"
    selector = { "app.kubernetes.io/name" = each.key }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
  wait_for_load_balancer = each.key == "hello-bff" && var.settings.exposure.mode == "internal-lb"
}

# App routing add-on ingress (managed NGINX) with TLS from Key Vault - only when platform-aks enables it.
resource "kubernetes_ingress_v1" "bff" {
  count = var.settings.exposure.mode == "app-routing" && contains(keys(local.http), "hello-bff") ? 1 : 0
  metadata {
    name      = "hello-bff"
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
    annotations = var.settings.exposure.tls_cert_keyvault_id == null ? {} : {
      "kubernetes.azure.com/tls-cert-keyvault-uri" = var.settings.exposure.tls_cert_keyvault_id
    }
  }
  spec {
    ingress_class_name = "webapprouting.kubernetes.azure.com"
    tls {
      hosts       = [var.settings.exposure.host]
      secret_name = "keyvault-${var.settings.exposure.tls_secret_name}"
    }
    rule {
      host = var.settings.exposure.host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.app["hello-bff"].metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "app" {
  for_each = local.apps
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
  }
  spec {
    max_unavailable = "1"
    selector {
      match_labels = { "app.kubernetes.io/name" = each.key }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  for_each = local.apps
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.hello.metadata[0].name
  }
  spec {
    min_replicas = each.value.min_replicas
    max_replicas = min(each.value.max_replicas, var.settings.replica_ceiling)
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app[each.key].metadata[0].name
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = each.value.target_cpu
        }
      }
    }
  }
}

check "artifacts_present" {
  assert {
    condition     = alltrue([for k in keys(local.apps) : can(regex("@sha256:[a-f0-9]{64}$", var.artifacts[local.meta[k].artifact].image))])
    error_message = "Every enabled app needs a digest-pinned image in var.artifacts (svc-bff, svc-orders-api, svc-catalog-api, svc-worker)."
  }
}
