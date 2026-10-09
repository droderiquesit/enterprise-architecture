# Fluent Bit aggregator and OTel gateway as Azure Container Apps with INTERNAL ingress only.
# AzAPI gap (azurerm 5.9 azurerm_container_app): no ingress.additionalPortMappings and no secret-volume
# item paths, both needed here (4317+4318 on one gateway, 24224+2020 on the aggregator; config files
# mounted with real file names). API version Microsoft.App/containerApps@2025-07-01 (GA).
module "aggregator_config" {
  source            = "../fluent-bit"
  role              = local.eh_enabled ? "aggregator" : "aggregator-forward"
  datadog_site      = var.datadog.site
  static_tags       = merge({ env = var.datadog.env }, var.datadog.extra_tags)
  aca_console_allow = var.aca_console_allow
}

module "gateway_config" {
  source                   = "../otel-collector"
  distribution             = var.gateway.distribution
  sampling                 = var.gateway.sampling
  sampling_percentage      = var.gateway.sampling_percentage
  otlp_logs                = var.gateway.otlp_logs
  bearer_auth              = var.gateway.auth != null
  fluentbit_metrics_target = local.agg_enabled ? "${local.agg_name}:2020" : null
  datadog_site             = var.datadog.site
  env                      = var.datadog.env
  memory_mib               = local.gw_mem_mib
  hostname                 = local.gw_name
  images                   = { upstream = var.images.otel_contrib, ddot = var.images.ddot_collector }
}

locals {
  config_dir = "${path.module}/../../config"

  agg_enabled = var.aggregator.hosting == "container_app"
  gw_enabled  = var.gateway.hosting == "container_app"

  agg_name = coalesce(var.names.aggregator, substr("${var.name_prefix}-flb", 0, 32))
  gw_name  = coalesce(var.names.gateway, substr("${var.name_prefix}-otelgw", 0, 32))

  intake_host = "http-intake.logs.${var.datadog.site}"

  identity_id = try(var.collector_identity.id, null)

  flb_parsers = module.aggregator_config.files["parsers.yaml"]
  flb_lua     = module.aggregator_config.files["lua/enterprise_hello.lua"]
  agg_config  = module.aggregator_config.files["fluent-bit.yaml"]


  agg_secrets = concat(
    [
      { name = "dd-api-key", keyVaultUrl = var.datadog.api_key_secret_id, identity = local.identity_id },
      { name = "flb-shared-key", keyVaultUrl = var.aggregator.forward_shared_key_secret_id, identity = local.identity_id },
      { name = "flb-config", value = local.agg_config },
      { name = "flb-parsers", value = local.flb_parsers },
      { name = "flb-lua", value = local.flb_lua },
    ],
    local.eh_enabled ? [{ name = "eventhub-conn", keyVaultUrl = local.eh_listen_secret_id, identity = local.identity_id }] : [],
    var.aggregator.forward_tls != null ? [
      { name = "flb-tls-crt", keyVaultUrl = var.aggregator.forward_tls.cert_secret_id, identity = local.identity_id },
      { name = "flb-tls-key", keyVaultUrl = var.aggregator.forward_tls.key_secret_id, identity = local.identity_id },
    ] : [],
  )

  agg_env = concat(
    [for k in sort(keys(module.aggregator_config.env)) : { name = k, value = module.aggregator_config.env[k] }],
    [
      { name = "DD_API_KEY", secretRef = "dd-api-key" },
      { name = "FLB_FORWARD_SHARED_KEY", secretRef = "flb-shared-key" },
      { name = "FLB_FORWARD_TLS", value = var.aggregator.forward_tls != null ? "on" : "off" },
      { name = "FLB_FORWARD_TLS_CRT", value = var.aggregator.forward_tls != null ? "/fluent-bit/etc/tls/tls.crt" : "" },
      { name = "FLB_FORWARD_TLS_KEY", value = var.aggregator.forward_tls != null ? "/fluent-bit/etc/tls/tls.key" : "" },
    ],
    local.eh_enabled ? [
      { name = "EVENTHUB_BROKERS", value = "${local.eh_fqdn}:9093" },
      { name = "EVENTHUB_TOPICS", value = "${var.event_hub.app_logs_hub},${var.event_hub.platform_logs_hub}" },
      { name = "EVENTHUB_CONSUMER_GROUP", value = var.event_hub.consumer_group },
      { name = "KAFKA_SECURITY_PROTOCOL", value = "SASL_SSL" },
      { name = "EVENTHUB_CONNECTION_STRING", secretRef = "eventhub-conn" },
    ] : [],
  )

  agg_volumes = concat(
    [
      { name = "flb-files", storageType = "Secret", secrets = [
        { secretRef = "flb-config", path = "fluent-bit.yaml" },
        { secretRef = "flb-parsers", path = "parsers.yaml" },
      ] },
      { name = "flb-lua", storageType = "Secret", secrets = [{ secretRef = "flb-lua", path = "enterprise_hello.lua" }] },
      { name = "flb-state", storageType = "EmptyDir" },
    ],
    var.aggregator.forward_tls != null ? [{ name = "flb-tls", storageType = "Secret", secrets = [
      { secretRef = "flb-tls-crt", path = "tls.crt" },
      { secretRef = "flb-tls-key", path = "tls.key" },
    ] }] : [],
  )

  agg_mounts = concat(
    [
      { volumeName = "flb-files", mountPath = "/fluent-bit/etc/eh" },
      { volumeName = "flb-lua", mountPath = "/fluent-bit/etc/eh/lua" },
      { volumeName = "flb-state", mountPath = "/var/fluent-bit/state" },
    ],
    var.aggregator.forward_tls != null ? [{ volumeName = "flb-tls", mountPath = "/fluent-bit/etc/tls" }] : [],
  )

  # ------------------------------------------------------------------------------------------- gateway
  gw_image = coalesce(var.gateway.image, module.gateway_config.image)
  gw_mem_mib = floor(
    endswith(var.gateway.memory, "Gi") ? tonumber(trimsuffix(var.gateway.memory, "Gi")) * 1024 : tonumber(trimsuffix(var.gateway.memory, "Mi"))
  )
  gw_args = module.gateway_config.args

  gw_secrets = concat(
    [{ name = "dd-api-key", keyVaultUrl = var.datadog.api_key_secret_id, identity = local.identity_id }],
    var.gateway.auth != null ? [{ name = "otlp-bearer-token", keyVaultUrl = var.gateway.auth.token_secret_id, identity = local.identity_id }] : [],
  )
  gw_env = concat(
    [{ name = "DD_API_KEY", secretRef = "dd-api-key" }],
    [for k in sort(keys(module.gateway_config.env)) : { name = k, value = module.gateway_config.env[k] }],
    [for k in module.gateway_config.config_env_order : { name = k, value = module.gateway_config.config_env[k] }],
    var.gateway.auth != null ? [{ name = "OTLP_BEARER_TOKEN", secretRef = "otlp-bearer-token" }] : [],
  )
}

resource "azapi_resource" "aggregator" {
  count     = local.agg_enabled ? 1 : 0
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = local.agg_name
  parent_id = var.resource_group.id
  location  = var.location
  tags      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity_id]
  }

  body = {
    properties = {
      environmentId       = var.container_apps.environment_id
      workloadProfileName = var.container_apps.workload_profile_name
      configuration = {
        activeRevisionsMode = "Single"
        ingress = {
          external    = false
          transport   = "tcp"
          targetPort  = 24224
          exposedPort = 24224
          # self-metrics for the gateway's Prometheus scrape (internal only)
          additionalPortMappings = [{ external = false, targetPort = 2020, exposedPort = 2020 }]
          traffic                = [{ latestRevision = true, weight = 100 }]
        }
        secrets = local.agg_secrets
      }
      template = {
        containers = [{
          name      = "fluent-bit"
          image     = var.aggregator.image
          args      = ["-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
          resources = { cpu = var.aggregator.cpu, memory = var.aggregator.memory }
          env       = local.agg_env
          probes = [
            { type = "Liveness", httpGet = { path = "/api/v1/health", port = 2020 }, periodSeconds = 30, failureThreshold = 3 },
            { type = "Readiness", tcpSocket = { port = 24224 }, periodSeconds = 10 },
          ]
          volumeMounts = local.agg_mounts
        }]
        scale = {
          minReplicas = var.aggregator.min_replicas
          maxReplicas = var.aggregator.max_replicas
          rules       = [{ name = "tcp-connections", tcp = { metadata = { concurrentConnections = "50" } } }]
        }
        volumes = local.agg_volumes
      }
    }
  }

  response_export_values = {
    fqdn = "properties.configuration.ingress.fqdn"
  }

  depends_on = [azurerm_role_assignment.kv_secrets_user]

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "aggregator.hosting = container_app needs container_apps.environment_id and collector_identity."
    }
    precondition {
      condition     = !local.eh_enabled || local.eh_listen_secret_id != null
      error_message = "The Kafka input needs the listen connection string in Key Vault: set event_hub.listen_secret_key_vault_id (create) or listen_connection_string_secret_id."
    }
  }
}

resource "azapi_resource" "gateway" {
  count     = local.gw_enabled ? 1 : 0
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = local.gw_name
  parent_id = var.resource_group.id
  location  = var.location
  tags      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity_id]
  }

  body = {
    properties = {
      environmentId       = var.container_apps.environment_id
      workloadProfileName = var.container_apps.workload_profile_name
      configuration = {
        activeRevisionsMode = "Single"
        ingress = {
          # OTLP/HTTP behind the environment's internal HTTPS endpoint; OTLP/gRPC as an extra internal TCP port
          external               = false
          transport              = "http"
          targetPort             = 4318
          allowInsecure          = false
          additionalPortMappings = [{ external = false, targetPort = 4317, exposedPort = 4317 }]
          traffic                = [{ latestRevision = true, weight = 100 }]
        }
        secrets = local.gw_secrets
      }
      template = {
        containers = [{
          name      = "otel-gateway"
          image     = local.gw_image
          args      = local.gw_args
          resources = { cpu = var.gateway.cpu, memory = var.gateway.memory }
          env       = local.gw_env
          probes = [
            { type = "Liveness", httpGet = { path = "/", port = 13133 }, periodSeconds = 30, failureThreshold = 3 },
            { type = "Readiness", httpGet = { path = "/", port = 13133 }, periodSeconds = 10 },
          ]
        }]
        scale = {
          minReplicas = var.gateway.min_replicas
          maxReplicas = var.gateway.max_replicas
          rules       = [{ name = "http-concurrency", http = { metadata = { concurrentRequests = "100" } } }]
        }
      }
    }
  }

  response_export_values = {
    fqdn = "properties.configuration.ingress.fqdn"
  }

  depends_on = [azurerm_role_assignment.kv_secrets_user]

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "gateway.hosting = container_app needs container_apps.environment_id and collector_identity."
    }
  }
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  count                = var.key_vault.grant_secrets_user && var.key_vault.id != null && var.collector_identity != null ? 1 : 0
  scope                = var.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.collector_identity.principal_id
  principal_type       = "ServicePrincipal"
}
