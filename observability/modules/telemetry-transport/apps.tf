# Fluent Bit aggregator and OTel gateway as Azure Container Apps with INTERNAL ingress only.
# AzAPI gap (azurerm 5.9 azurerm_container_app): no ingress.additionalPortMappings and no secret-volume
# item paths, both needed here (4317+4318 on one gateway, 24224+2020 on the aggregator; config files
# mounted with real file names). API version Microsoft.App/containerApps@2025-07-01 (GA).
# Secrets: dsv-fetch init containers read them from Delinea DSV with the collector identity into replica-scoped
# EmptyDir volumes (Fluent Bit: env-yaml include; OTel: ${file:...}). Init containers can use managed identity
# only in a workload-profiles environment on the Consumption profile (Microsoft Learn, ACA managed identity).
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

  agg_enabled = var.aggregator.hosting == "container_app"
  gw_enabled  = var.gateway.hosting == "container_app"

  agg_name = coalesce(var.names.aggregator, substr("${var.name_prefix}-flb", 0, 32))
  gw_name  = coalesce(var.names.gateway, substr("${var.name_prefix}-otelgw", 0, 32))

  intake_host = "http-intake.logs.${var.datadog.site}"

  identity_id = try(var.collector_identity.id, null)

  flb_parsers = module.aggregator_config.files["parsers.yaml"]
  flb_lua     = module.aggregator_config.files["lua/enterprise_hello.lua"]
  agg_config  = module.aggregator_config.files["fluent-bit.yaml"]


  # ---------------------------------------------------------------- Delinea DSV (dsv-fetch init containers)
  dsv_base_url = coalesce(var.secrets.base_url, "https://${coalesce(var.secrets.tenant, "unset")}.secretsvaultcloud.${coalesce(var.secrets.tld, "com")}/v1")
  dsv_env = merge(
    var.secrets.tenant == null ? {} : { DSV_TENANT = var.secrets.tenant },
    var.secrets.tld == null ? {} : { DSV_TLD = var.secrets.tld },
    { DSV_BASE_URL = local.dsv_base_url, DSV_AUTH = var.secrets.auth, DSV_TIMEOUT_SECONDS = "10" },
    local.identity_id == null ? {} : { AZURE_CLIENT_ID = var.collector_identity.client_id },
  )
  dsv_env_list = [for k in sort(keys(local.dsv_env)) : { name = k, value = local.dsv_env[k] }]
  # private registry of the dsv-fetch image (pulled with the collector identity; public images need none)
  fetch_registry = var.secrets.fetch_image == null ? null : (
    can(regex("^[a-z0-9.-]+\\.[a-z]+(:[0-9]+)?/", var.secrets.fetch_image)) && !startswith(var.secrets.fetch_image, "docker.io/") ? split("/", var.secrets.fetch_image)[0] : null
  )
  registries = local.fetch_registry == null ? [] : [{ server = local.fetch_registry, identity = local.identity_id }]

  # aggregator secrets: Fluent Bit env-yaml (included by aggregator.yaml) + optional TLS files
  agg_secret_refs = merge(
    { DD_API_KEY = var.datadog.api_key_ref },
    var.aggregator.forward_shared_key_ref == null ? {} : { FLB_FORWARD_SHARED_KEY = var.aggregator.forward_shared_key_ref },
    local.eh_enabled && local.eh_listen_ref != null ? { EVENTHUB_CONNECTION_STRING = local.eh_listen_ref } : {},
  )
  agg_init = concat(
    [{
      name         = "dsv-fetch"
      image        = var.secrets.fetch_image
      args         = concat(["init", "--out", "/dsv-secrets", "--format", "env-yaml", "--env-yaml-name", "fluentbit-env.yaml"], flatten([for k in sort(keys(local.agg_secret_refs)) : ["--map", "${k}=${local.agg_secret_refs[k]}"]]))
      resources    = { cpu = 0.25, memory = "0.5Gi" }
      env          = local.dsv_env_list
      volumeMounts = [{ volumeName = "dsv-secrets", mountPath = "/dsv-secrets" }]
    }],
    var.aggregator.forward_tls != null ? [{
      name         = "dsv-fetch-tls"
      image        = var.secrets.fetch_image
      args         = ["init", "--out", "/dsv-tls", "--format", "files", "--map", "tls.crt=${var.aggregator.forward_tls.cert_ref}", "--map", "tls.key=${var.aggregator.forward_tls.key_ref}"]
      resources    = { cpu = 0.25, memory = "0.5Gi" }
      env          = local.dsv_env_list
      volumeMounts = [{ volumeName = "dsv-tls", mountPath = "/dsv-tls" }]
    }] : [],
  )

  # ACA secrets carry only the (non-secret) config files mounted as a Secret volume
  agg_secrets = [
    { name = "flb-config", value = local.agg_config },
    { name = "flb-parsers", value = local.flb_parsers },
    { name = "flb-lua", value = local.flb_lua },
  ]

  agg_env = concat(
    [for k in sort(keys(module.aggregator_config.env)) : { name = k, value = module.aggregator_config.env[k] }],
    [
      { name = "FLB_FORWARD_TLS", value = var.aggregator.forward_tls != null ? "on" : "off" },
      { name = "FLB_FORWARD_TLS_CRT", value = var.aggregator.forward_tls != null ? "/dsv-tls/tls.crt" : "" },
      { name = "FLB_FORWARD_TLS_KEY", value = var.aggregator.forward_tls != null ? "/dsv-tls/tls.key" : "" },
    ],
    local.eh_enabled ? [
      { name = "EVENTHUB_BROKERS", value = "${local.eh_fqdn}:9093" },
      { name = "EVENTHUB_TOPICS", value = local.eventhub_topics },
      { name = "FLB_EVENTHUB_APP_TOPIC", value = var.event_hub.app_logs_hub },
      { name = "EVENTHUB_CONSUMER_GROUP", value = var.event_hub.consumer_group },
      { name = "KAFKA_SECURITY_PROTOCOL", value = "SASL_SSL" },
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
      { name = "dsv-secrets", storageType = "EmptyDir" },
    ],
    var.aggregator.forward_tls != null ? [{ name = "dsv-tls", storageType = "EmptyDir" }] : [],
  )

  agg_mounts = concat(
    [
      { volumeName = "flb-files", mountPath = "/fluent-bit/etc/eh" },
      { volumeName = "flb-lua", mountPath = "/fluent-bit/etc/eh/lua" },
      { volumeName = "flb-state", mountPath = "/var/fluent-bit/state" },
      { volumeName = "dsv-secrets", mountPath = "/dsv-secrets" },
    ],
    var.aggregator.forward_tls != null ? [{ volumeName = "dsv-tls", mountPath = "/dsv-tls" }] : [],
  )

  # ------------------------------------------------------------------------------------------- gateway
  gw_image = coalesce(var.gateway.image, module.gateway_config.image)
  gw_mem_mib = floor(
    endswith(var.gateway.memory, "Gi") ? tonumber(trimsuffix(var.gateway.memory, "Gi")) * 1024 : tonumber(trimsuffix(var.gateway.memory, "Mi"))
  )
  gw_args = module.gateway_config.args

  # gateway secrets: FILES read by the collector config (${file:/dsv-secrets/<name>})
  gw_secret_refs = merge(
    { "dd-api-key" = var.datadog.api_key_ref },
    var.gateway.auth != null ? { "otlp-bearer-token" = var.gateway.auth.token_ref } : {},
  )
  gw_init = [{
    name  = "dsv-fetch"
    image = var.secrets.fetch_image
    # 0444: the collector images run as non-root uids (contrib 10001) other than dsv-fetch (65532) and ACA has no
    # runAsUser/fsGroup; the replica-scoped EmptyDir is visible only to the containers of this replica
    args         = concat(["init", "--out", "/dsv-secrets", "--format", "files", "--file-mode", "0444"], flatten([for k in sort(keys(local.gw_secret_refs)) : ["--map", "${k}=${local.gw_secret_refs[k]}"]]))
    resources    = { cpu = 0.25, memory = "0.5Gi" }
    env          = local.dsv_env_list
    volumeMounts = [{ volumeName = "dsv-secrets", mountPath = "/dsv-secrets" }]
  }]
  gw_env = concat(
    [for k in sort(keys(module.gateway_config.env)) : { name = k, value = module.gateway_config.env[k] }],
    [for k in module.gateway_config.config_env_order : { name = k, value = module.gateway_config.config_env[k] }],
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
        secrets    = local.agg_secrets
        registries = local.registries
      }
      template = {
        initContainers = local.agg_init
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

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "aggregator.hosting = container_app needs container_apps.environment_id and collector_identity."
    }
    precondition {
      condition     = !local.eh_enabled || local.eh_listen_ref != null
      error_message = "The Kafka input needs the listen connection string in DSV: set event_hub.listen_connection_string_ref (dsv://...)."
    }
    precondition {
      condition     = var.container_apps == null || try(var.container_apps.workload_profile_name, "") == "Consumption"
      error_message = "dsv-fetch init containers need managed identity, which ACA offers to init containers only on the Consumption profile of a workload-profiles environment."
    }
    precondition {
      condition     = var.secrets.fetch_image != null
      error_message = "The aggregator reads its keys from DSV with the dsv-fetch init container: set secrets.fetch_image."
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
        registries = local.registries
      }
      template = {
        initContainers = local.gw_init
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
          volumeMounts = [{ volumeName = "dsv-secrets", mountPath = "/dsv-secrets" }]
        }]
        scale = {
          minReplicas = var.gateway.min_replicas
          maxReplicas = var.gateway.max_replicas
          rules       = [{ name = "http-concurrency", http = { metadata = { concurrentRequests = "100" } } }]
        }
        volumes = [{ name = "dsv-secrets", storageType = "EmptyDir" }]
      }
    }
  }

  response_export_values = {
    fqdn = "properties.configuration.ingress.fqdn"
  }

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "gateway.hosting = container_app needs container_apps.environment_id and collector_identity."
    }
    precondition {
      condition     = var.container_apps == null || try(var.container_apps.workload_profile_name, "") == "Consumption"
      error_message = "dsv-fetch init containers need managed identity, which ACA offers to init containers only on the Consumption profile of a workload-profiles environment."
    }
    precondition {
      condition     = var.secrets.fetch_image != null
      error_message = "The gateway reads its keys from DSV with the dsv-fetch init container: set secrets.fetch_image."
    }
  }
}
