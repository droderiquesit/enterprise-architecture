# Fleet collection tier of the transport (package 3.0.0; dsv-fetch static binary since 4.0.0):
#  * Datadog Observability Pipelines (log_pipeline = observability_pipelines, default): pipeline definition
#    (modules/observability-pipeline) + the Worker as a Container App with INTERNAL ingress (24224 fluent source for
#    Fluent Bit edge collectors, 8282 Datadog Agent source, 8686 API/health). Event Hubs are read by the Worker's
#    kafka source; the Fluent Bit aggregator is not deployed in this mode (no double consumption of the hubs).
#  * Datadog Agent APM gateway (apm.managed_runtime_path = agent_gateway): an Agent Container App receiving Datadog
#    tracer payloads and profiles on 8126 for managed runtimes without a node Agent.
# Secrets: Delinea DSV only. The Worker sources a dsv-fetch dotenv file (init container on the Consumption profile,
# refresher container elsewhere); the APM gateway Agent resolves ENC[dsv://...] with dsv-fetch as its secret backend.
module "fleet" {
  source = "../fleet-policy"
  policy = var.fleet_policy
  env    = var.datadog.env
}

locals {
  log_pipeline = coalesce(var.log_pipeline, module.fleet.log_pipeline)
  op_mode      = local.log_pipeline == "observability_pipelines"
  opv          = var.observability_pipelines
  op_create    = local.op_mode && local.opv.pipeline_id == null
  op_hosted    = local.op_mode && local.opv.hosting == "container_app"
  opw          = module.fleet.op_worker

  opw_name    = coalesce(var.names.op_worker, substr("${var.name_prefix}-opw", 0, 32))
  opw_image   = coalesce(local.opv.image, "datadog/observability-pipelines-worker:${try(local.opw.version, "2.22.0")}")
  opw_profile = coalesce(local.opv.workload_profile_name, try(var.container_apps.workload_profile_name, "Consumption"))
  opw_refresh = local.opw_profile != "Consumption"

  pipeline_id = !local.op_mode ? null : (local.op_create ? module.pipeline[0].pipeline_id : local.opv.pipeline_id)
  # env contract of the Worker (non-secret) + DSV references of its secrets
  opw_env_base = local.op_create ? module.pipeline[0].worker_env : merge(
    {
      DD_OP_PIPELINE_ID                  = coalesce(local.opv.pipeline_id, "unset")
      DD_SITE                            = var.datadog.site
      DD_OP_API_ENABLED                  = "true"
      DD_OP_API_ADDRESS                  = "0.0.0.0:8686"
      DD_OP_DATA_DIR_BASE                = "/var/lib/observability-pipelines-worker"
      DD_OP_SOURCE_FLUENT_ADDRESS        = "0.0.0.0:24224"
      DD_OP_SOURCE_DATADOG_AGENT_ADDRESS = "0.0.0.0:8282"
    },
    local.eh_enabled ? { DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS = "${local.eh_fqdn}:9093", DD_OP_SOURCE_KAFKA_SASL_USERNAME = "$ConnectionString" } : {},
  )
  opw_secret_refs = local.op_create ? module.pipeline[0].worker_secret_refs : merge(
    { DD_API_KEY = var.datadog.api_key_ref },
    local.eh_enabled && local.eh_listen_ref != null ? { DD_OP_SOURCE_KAFKA_SASL_PASSWORD = local.eh_listen_ref } : {},
  )
  opw_command = local.op_create ? module.pipeline[0].worker_command : ["/bin/sh", "-c", "set -eu; f=/dsv-secrets/opw.env; i=0; while [ ! -s \"$f\" ]; do i=$((i+1)); if [ $i -gt 60 ]; then echo 'opw: dsv-fetch secrets file missing - refusing to start' >&2; exit 1; fi; sleep 2; done; set -a; . \"$f\"; set +a; h=$${HOSTNAME:-opw}; export VECTOR_HOSTNAME=\"$h\"; d=\"$${DD_OP_DATA_DIR_BASE:-/var/lib/observability-pipelines-worker}/$h\"; mkdir -p \"$d\"; export DD_OP_DATA_DIR=\"$d\"; exec /usr/bin/observability-pipelines-worker run"]

  opw_fetch_args = concat(["init", "--out", "/dsv-secrets", "--format", "dotenv", "--dotenv-name", "opw.env"],
  flatten([for k in sort(keys(local.opw_secret_refs)) : ["--map", "${k}=${local.opw_secret_refs[k]}"]]))
  opw_fetch = {
    name         = "dsv-fetch"
    image        = var.secrets.fetch_image
    args         = local.opw_fetch_args
    resources    = { cpu = 0.25, memory = "0.5Gi" }
    env          = local.dsv_env_list
    volumeMounts = [{ volumeName = "dsv-secrets", mountPath = "/dsv-secrets" }]
  }
  opw_buffer_volume = local.opv.buffer_storage == "azure_files" ? { name = "opw-data", storageType = "AzureFile", storageName = local.opv.azure_files_storage } : { name = "opw-data", storageType = "EmptyDir" }

  op_endpoint_host = !local.op_mode ? null : (local.op_hosted ? try(azapi_resource.op_worker[0].output.fqdn, null) : try(local.opv.external_endpoint.host, null))
  op_endpoint_port = try(local.opv.external_endpoint.port, 24224)

  # ------------------------------------------------------------------ APM gateway (Datadog Agent)
  apm_hosted = var.apm_gateway.hosting == "container_app"
  apm_name   = coalesce(var.names.apm_gateway, substr("${var.name_prefix}-apm", 0, 32))
  # single Agent pin of the fleet policy (agent.image:agent.version); no built-in fallback (precondition below)
  apm_image = try(coalesce(var.apm_gateway.image, module.fleet.agent_image), null)
  apm_url   = local.apm_hosted ? (try(azapi_resource.apm_gateway[0].output.fqdn, null) == null ? null : "http://${azapi_resource.apm_gateway[0].output.fqdn}:8126") : var.apm_gateway.external_url
  apm_dsv_config = jsonencode(merge(
    var.secrets.tenant == null ? {} : { DSV_TENANT = var.secrets.tenant },
    var.secrets.tld == null ? {} : { DSV_TLD = var.secrets.tld },
    { DSV_BASE_URL = local.dsv_base_url, DSV_AUTH = var.secrets.auth, DSV_TIMEOUT_SECONDS = "10" },
    local.identity_id == null ? {} : { AZURE_CLIENT_ID = var.collector_identity.client_id },
  ))
  apm_datadog_yaml = yamlencode({
    api_key                    = "ENC[${var.datadog.api_key_ref}]"
    site                       = var.datadog.site
    env                        = var.datadog.env
    tags                       = [for k in sort(keys(local.collector_tags)) : "${k}:${local.collector_tags[k]}"]
    logs_enabled               = false
    apm_config                 = merge({ enabled = true, apm_non_local_traffic = true, receiver_port = 8126 }, length(module.fleet.agent_apm_ignore_resources) == 0 ? {} : { ignore_resources = module.fleet.agent_apm_ignore_resources })
    process_config             = { process_collection = { enabled = false } }
    remote_configuration       = { enabled = try(module.fleet.agent.remote_configuration, true) }
    health_port                = 5555
    enable_metadata_collection = true
    secret_backend_command     = "/opt/dsv-fetch/dsv-fetch"
    secret_backend_arguments   = ["agent-backend", "--config", "/eh/dsv/dsv.json"]
    secret_backend_timeout     = 30
  })
  apm_container_env = [
    { name = "DD_SITE", value = var.datadog.site },
    # the image's init requires a non-empty DD_API_KEY; ENC[] is resolved by the secret backend
    { name = "DD_API_KEY", value = "ENC[${var.datadog.api_key_ref}]" },
    { name = "DD_APM_ENABLED", value = "true" },
    { name = "DD_APM_NON_LOCAL_TRAFFIC", value = "true" },
    { name = "DD_LOGS_ENABLED", value = "false" },
    { name = "DD_PROCESS_AGENT_ENABLED", value = "false" },
    { name = "DD_HEALTH_PORT", value = "5555" },
  ]
  # the static dsv-fetch binary (copied by the init container into the replica-scoped EmptyDir /dsv-bin) re-installs
  # itself as root (the Agent user in the container), mode 0500 - the owner/permission rule of secret_backend_command
  apm_command = ["/bin/sh", "-c", "/dsv-bin/dsv-fetch install --dest /opt/dsv-fetch/dsv-fetch && cp /eh/agent/datadog.yaml /etc/datadog-agent/datadog.yaml && export DD_HOSTNAME=\"$${HOSTNAME}\" && exec /bin/entrypoint.sh"]
  apm_fetch_install = {
    name         = "dsv-fetch-install"
    image        = var.secrets.fetch_image
    args         = ["install", "--dest", "/dsv-bin/dsv-fetch"]
    resources    = { cpu = 0.25, memory = "0.5Gi" }
    volumeMounts = [{ volumeName = "dsv-bin", mountPath = "/dsv-bin" }]
  }
  collector_tags = merge(var.default_tags, { env = var.datadog.env }, var.datadog.extra_tags)
}

module "pipeline" {
  source = "../observability-pipeline"
  count  = local.op_create ? 1 : 0

  name         = coalesce(local.opv.name, "${var.name_prefix}-logs")
  env          = var.datadog.env
  datadog_site = var.datadog.site
  tag_policy   = var.tag_policy
  default_tags = local.collector_tags
  sources = {
    fluent_bit    = true
    datadog_agent = true
    opentelemetry = local.opv.otlp_logs_source
    eventhub = local.eh_enabled ? {
      topics    = distinct([var.event_hub.app_logs_hub, var.event_hub.platform_logs_hub, local.activity_hub])
      group_id  = "observability-pipelines"
      app_topic = var.event_hub.app_logs_hub
    } : null
  }
  eventhub_bootstrap = local.eh_enabled ? "${local.eh_fqdn}:9093" : null
  azure = {
    service           = "azure"
    aca_console_allow = var.aca_console_allow
    scope_tags        = local.opv.azure.scope_tags
    static_tags       = local.opv.azure.static_tags
    daily_quota_bytes = local.opv.azure.daily_quota_bytes
    sample_categories = local.opv.azure.sample_categories
  }
  redaction = { extra_patterns = local.opv.redaction_extra_patterns }
  archive = {
    enabled        = local.opv.archive.enabled
    container_name = local.opv.archive.container_name
    blob_prefix    = local.opv.archive.blob_prefix
  }
  buffer = { disk_max_bytes = try(local.opw.disk_buffer_bytes, 1073741824) }
  secret_refs = {
    api_key                    = var.datadog.api_key_ref
    eventhub_connection_string = local.eh_enabled ? local.eh_listen_ref : null
    archive_connection_string  = local.opv.archive.connection_string_ref
  }
}

resource "azapi_resource" "op_worker" {
  count     = local.op_hosted ? 1 : 0
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = local.opw_name
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
      workloadProfileName = local.opw_profile
      configuration = {
        activeRevisionsMode = "Single"
        ingress = {
          external    = false
          transport   = "tcp"
          targetPort  = 24224
          exposedPort = 24224
          additionalPortMappings = concat(
            [
              { external = false, targetPort = 8282, exposedPort = 8282 },
              { external = false, targetPort = 8686, exposedPort = 8686 },
            ],
            local.opv.otlp_logs_source ? [{ external = false, targetPort = 4317, exposedPort = 4317 }, { external = false, targetPort = 4318, exposedPort = 4318 }] : [],
          )
          traffic = [{ latestRevision = true, weight = 100 }]
        }
        registries = local.registries
      }
      template = {
        initContainers = local.opw_refresh ? [] : [local.opw_fetch]
        containers = concat(
          [{
            name      = "observability-pipelines-worker"
            image     = local.opw_image
            command   = local.opw_command
            resources = { cpu = try(local.opw.cpu, 1), memory = try(local.opw.memory, "2Gi") }
            env       = [for k in sort(keys(local.opw_env_base)) : { name = k, value = local.opw_env_base[k] }]
            probes = [
              { type = "Startup", tcpSocket = { port = 8686 }, periodSeconds = 10, failureThreshold = 30 },
              { type = "Liveness", httpGet = { path = "/health", port = 8686 }, periodSeconds = 30, failureThreshold = 3 },
              { type = "Readiness", httpGet = { path = "/health", port = 8686 }, periodSeconds = 10 },
            ]
            volumeMounts = [
              { volumeName = "dsv-secrets", mountPath = "/dsv-secrets" },
              { volumeName = "opw-data", mountPath = "/var/lib/observability-pipelines-worker" },
            ]
          }],
          # dedicated profiles: init containers get no managed identity -> the binary keeps running and re-resolves every
          # hour (after a failure every 30 s) with a fresh token (dsv-fetch 2.x `init --refresh-seconds`)
          local.opw_refresh ? [merge(local.opw_fetch, { name = "dsv-fetch-refresher", args = concat(local.opw_fetch_args, ["--refresh-seconds", "3600", "--retry-seconds", "30"]) })] : [],
        )
        scale = {
          minReplicas = try(local.opw.min_replicas, 2)
          maxReplicas = try(local.opw.max_replicas, 6)
          rules = [
            { name = "cpu", custom = { type = "cpu", metadata = { type = "Utilization", value = "70" } } },
            { name = "tcp-connections", tcp = { metadata = { concurrentConnections = "200" } } },
          ]
        }
        volumes = [{ name = "dsv-secrets", storageType = "EmptyDir" }, local.opw_buffer_volume]
      }
    }
  }

  response_export_values = {
    fqdn = "properties.configuration.ingress.fqdn"
  }

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "observability_pipelines.hosting = container_app needs container_apps.environment_id and collector_identity."
    }
    precondition {
      condition     = var.secrets.fetch_image != null
      error_message = "The Worker reads its keys from DSV with dsv-fetch: set secrets.fetch_image."
    }
    precondition {
      condition     = !local.eh_enabled || local.eh_listen_ref != null
      error_message = "The Worker's kafka source needs the Event Hubs Listen connection string in DSV: set event_hub.listen_connection_string_ref (dsv://...)."
    }
  }
}

resource "azapi_resource" "apm_gateway" {
  count     = local.apm_hosted ? 1 : 0
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = local.apm_name
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
          targetPort  = 8126
          exposedPort = 8126
          traffic     = [{ latestRevision = true, weight = 100 }]
        }
        # the dsv-fetch-install init container pulls the img-dsv-fetch image from the private registry
        registries = local.registries
        # non-secret files mounted as a Secret volume (ACA has no config-file volume type)
        secrets = [
          { name = "agent-config", value = local.apm_datadog_yaml },
          { name = "dsv-config", value = local.apm_dsv_config },
        ]
      }
      template = {
        containers = [{
          name  = "datadog-agent"
          image = local.apm_image
          # dsv-fetch becomes the Agent's secret backend (root-owned, 0500, static binary), the rendered
          # datadog.yaml is installed, every replica reports under its own hostname, then the image entrypoint runs
          command   = local.apm_command
          resources = { cpu = var.apm_gateway.cpu, memory = var.apm_gateway.memory }
          env       = local.apm_container_env
          probes = [
            { type = "Liveness", httpGet = { path = "/live", port = 5555 }, initialDelaySeconds = 30, periodSeconds = 30, failureThreshold = 5 },
            { type = "Readiness", httpGet = { path = "/ready", port = 5555 }, periodSeconds = 15 },
          ]
          volumeMounts = [
            { volumeName = "agent-config", mountPath = "/eh/agent" },
            { volumeName = "dsv", mountPath = "/eh/dsv" },
            { volumeName = "dsv-bin", mountPath = "/dsv-bin" },
          ]
        }]
        initContainers = [local.apm_fetch_install]
        scale = {
          minReplicas = var.apm_gateway.min_replicas
          maxReplicas = var.apm_gateway.max_replicas
          rules       = [{ name = "tcp-connections", tcp = { metadata = { concurrentConnections = "100" } } }]
        }
        volumes = [
          { name = "agent-config", storageType = "Secret", secrets = [{ secretRef = "agent-config", path = "datadog.yaml" }] },
          { name = "dsv", storageType = "Secret", secrets = [{ secretRef = "dsv-config", path = "dsv.json" }] },
          { name = "dsv-bin", storageType = "EmptyDir" },
        ]
      }
    }
  }

  response_export_values = {
    fqdn = "properties.configuration.ingress.fqdn"
  }

  lifecycle {
    precondition {
      condition     = var.container_apps != null && local.identity_id != null
      error_message = "apm_gateway.hosting = container_app needs container_apps.environment_id and collector_identity (DSV access of the Agent)."
    }
    precondition {
      condition     = var.secrets.fetch_image != null
      error_message = "The APM gateway Agent's secret backend is the dsv-fetch binary from its image: set secrets.fetch_image."
    }
    precondition {
      condition     = local.apm_image != null
      error_message = "The fleet policy has no Datadog Agent pin: set agent.image + agent.version (or apm_gateway.image)."
    }
  }
}
