# Instrumentation hook: computes everything an application's OWN deployment root needs to apply so that
# the workload emits telemetry along the authoritative path (ADR-0001 §10, README-transport.md):
#   env vars, Kubernetes patch, Container Apps sidecar patch, App Service/Functions app settings, ACI sidecar.
# Values only; secrets are Key Vault secret references. No resources, no providers.
locals {
  s         = var.service
  container = coalesce(var.container_name, var.service.service)

  log_route = {
    aks        = "daemonset"
    vm         = "host"
    vmss       = "host"
    aca        = "sidecar"
    aci        = "sidecar"
    appservice = "eventhub"
    functions  = "eventhub"
    logicapp   = "eventhub"
  }[var.architecture]

  # where OTLP goes: node-local Agent (AKS DaemonSet hostPort / VM agent) or the OTel gateway
  otlp_target = contains(["aks", "vm", "vmss"], var.architecture) ? "agent" : "gateway"

  default_protocol = local.otlp_target == "agent" ? "grpc" : var.telemetry.otlp.default_protocol
  protocol         = coalesce(var.otlp_protocol, local.default_protocol)

  agent_port = local.protocol == "grpc" ? var.telemetry.otlp.node_agent_grpc_port : var.telemetry.otlp.node_agent_http_port
  otlp_endpoint = {
    agent   = var.architecture == "aks" ? "http://$(DD_AGENT_HOST):${local.agent_port}" : (local.protocol == "grpc" ? var.telemetry.otlp.host_agent_grpc_endpoint : "http://localhost:${var.telemetry.otlp.node_agent_http_port}")
    gateway = local.protocol == "grpc" ? var.telemetry.otlp.grpc_endpoint : var.telemetry.otlp.http_endpoint
  }[local.otlp_target]

  cloud_platform = {
    aks        = "azure_aks"
    aca        = "azure_container_apps"
    aci        = "azure_container_instances"
    appservice = "azure_app_service"
    functions  = "azure_functions"
    logicapp   = "azure_app_service"
    vm         = "azure_vm"
    vmss       = "azure_vm"
  }[var.architecture]

  resource_attributes = merge(
    {
      "deployment.environment.name" = local.s.env
      "deployment.environment"      = local.s.env
      "service.version"             = local.s.version
      "service.namespace"           = local.s.application
      "team"                        = local.s.team
      "domain"                      = local.s.domain
      "tier"                        = local.s.tier
      "application"                 = local.s.application
      "owner"                       = local.s.owner
      "region"                      = local.s.region
      "cloud.provider"              = "azure"
      "cloud.platform"              = local.cloud_platform
    },
    var.extra_resource_attributes,
  )
  otel_resource_attributes = join(",", [for k in sort(keys(local.resource_attributes)) : "${k}=${local.resource_attributes[k]}"])

  dd_tags = join(",", [
    "env:${local.s.env}", "service:${local.s.service}", "version:${local.s.version}", "team:${local.s.team}",
    "domain:${local.s.domain}", "tier:${local.s.tier}", "application:${local.s.application}", "region:${local.s.region}",
  ])

  runtime_env = {
    dotnet = {
      OTEL_DOTNET_AUTO_LOGS_ENABLED = "false"
    }
    python = {
      OTEL_PYTHON_LOG_CORRELATION                      = "true"
      OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED = "false"
      OTEL_PYTHON_EXCLUDED_URLS                        = "healthz,readyz,version"
    }
    node = {
      OTEL_NODE_RESOURCE_DETECTORS = "env,host,os"
    }
    java = {
      OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED = "true"
    }
    browser = {}
  }

  # Contract-provided defaults (per runtime) first, module computed values win.
  contract_env = merge(lookup(var.telemetry.env, "common", {}), lookup(var.telemetry.env, var.runtime, {}))

  base_env = var.runtime == "browser" ? {
    DD_SITE    = var.telemetry.datadog_site
    DD_ENV     = local.s.env
    DD_SERVICE = local.s.service
    DD_VERSION = local.s.version
    } : merge(local.contract_env, local.runtime_env[var.runtime], {
      DD_ENV                      = local.s.env
      DD_SERVICE                  = local.s.service
      DD_VERSION                  = local.s.version
      OTEL_SERVICE_NAME           = local.s.service
      OTEL_RESOURCE_ATTRIBUTES    = local.otel_resource_attributes
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL = local.protocol
      OTEL_TRACES_SAMPLER         = "parentbased_traceidratio"
      OTEL_TRACES_SAMPLER_ARG     = tostring(var.trace_sample_ratio)
      OTEL_TRACES_EXPORTER        = "otlp"
      OTEL_METRICS_EXPORTER       = "otlp"
      # application logs travel through Fluent Bit only (no OTLP logs -> no duplicates)
      OTEL_LOGS_EXPORTER = "none"
      OTEL_PROPAGATORS   = "tracecontext,baggage"
  })

  # LOG_FILE_PATH only where a file tailer is the collector (sidecar, host service)
  env = merge(
    local.base_env,
    contains(["sidecar", "host"], local.log_route) && var.runtime != "browser" ? { LOG_FILE_PATH = var.log_file_path } : {},
    var.architecture == "functions" ? { AzureFunctionsJobHost__telemetryMode = "OpenTelemetry" } : {},
  )

  # env vars whose VALUE must come from Key Vault (name -> versionless secret id)
  secret_env = var.runtime != "browser" && local.otlp_target == "gateway" && var.telemetry.otlp.headers_secret_id != null ? {
    OTEL_EXPORTER_OTLP_HEADERS = var.telemetry.otlp.headers_secret_id
  } : {}

  # ---------------------------------------------------------------- Fluent Bit sidecar (aca / aci)
  log_dir         = replace(var.log_file_path, "/\\/[^\\/]+$/", "")
  intake_host     = coalesce(var.telemetry.fluentbit.logs_intake_host, "http-intake.logs.${var.telemetry.datadog_site}")
  sidecar_forward = var.telemetry.fluentbit.sidecar_mode == "forward"
  dd_source = {
    dotnet  = "csharp"
    python  = "python"
    node    = "nodejs"
    java    = "java"
    browser = "browser"
  }[var.runtime]

  sidecar_env = merge(
    {
      LOG_FILE_PATH  = var.log_file_path
      FLB_STATE_DIR  = "${local.log_dir}/.flb"
      FLB_DD_SERVICE = local.s.service
      FLB_DD_SOURCE  = local.dd_source
      FLB_DD_TAGS    = local.dd_tags
    },
    local.sidecar_forward ? {
      FLB_FORWARD_HOST       = var.telemetry.fluentbit.forward_host
      FLB_FORWARD_PORT       = tostring(var.telemetry.fluentbit.forward_port)
      FLB_FORWARD_TLS        = "off"
      FLB_FORWARD_TLS_VERIFY = "on"
      } : {
      FLB_DD_HOST = local.intake_host
      FLB_DD_PORT = "443"
      FLB_DD_TLS  = "on"
    },
  )
  sidecar_secret_env = local.sidecar_forward ? (
    var.telemetry.fluentbit.forward_shared_key_secret_id == null ? {} : { FLB_FORWARD_SHARED_KEY = var.telemetry.fluentbit.forward_shared_key_secret_id }
  ) : { DD_API_KEY = var.telemetry.api_key_secret_id }

  sidecar_config      = local.sidecar_forward ? var.telemetry.fluentbit.sidecar_forward_config : var.telemetry.fluentbit.sidecar_config
  sidecar_files_ready = local.sidecar_config != null && var.telemetry.fluentbit.sidecar_parsers != null && var.telemetry.fluentbit.sidecar_lua != null

  secret_name = { for k, v in merge(local.secret_env, local.sidecar_secret_env) : k => lower(replace(k, "_", "-")) }

  uses_sidecar = local.log_route == "sidecar"

  container_app_patch = {
    secrets = concat(
      [for k, id in merge(local.secret_env, local.uses_sidecar ? local.sidecar_secret_env : {}) : {
        name                = local.secret_name[k]
        key_vault_secret_id = id
        identity            = coalesce(var.key_vault_identity_id, "System")
        value               = null
      }],
      local.uses_sidecar && local.sidecar_files_ready ? [
        { name = "flb-config", value = local.sidecar_config, key_vault_secret_id = null, identity = null },
        { name = "flb-parsers", value = var.telemetry.fluentbit.sidecar_parsers, key_vault_secret_id = null, identity = null },
        { name = "flb-lua", value = var.telemetry.fluentbit.sidecar_lua, key_vault_secret_id = null, identity = null },
      ] : [],
    )
    volumes = local.uses_sidecar ? [
      { name = "app-logs", storage_type = "EmptyDir" },
      { name = "flb-files", storage_type = "Secret" },
    ] : []
    app_container = {
      name = local.container
      env = concat(
        [for k in sort(keys(local.env)) : { name = k, value = local.env[k], secret_name = null }],
        [for k in sort(keys(local.secret_env)) : { name = k, value = null, secret_name = local.secret_name[k] }],
      )
      volume_mounts = local.uses_sidecar ? [{ name = "app-logs", path = local.log_dir, sub_path = null }] : []
    }
    sidecars = local.uses_sidecar ? [{
      name   = "fluent-bit"
      image  = var.telemetry.fluentbit.sidecar_image
      cpu    = var.sidecar_resources.cpu
      memory = var.sidecar_resources.memory
      args   = ["-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
      env = concat(
        [for k in sort(keys(local.sidecar_env)) : { name = k, value = local.sidecar_env[k], secret_name = null }],
        [for k in sort(keys(local.sidecar_secret_env)) : { name = k, value = null, secret_name = local.secret_name[k] }],
      )
      volume_mounts = [
        { name = "app-logs", path = local.log_dir, sub_path = null },
        { name = "flb-files", path = "/fluent-bit/etc/eh/fluent-bit.yaml", sub_path = "flb-config" },
        { name = "flb-files", path = "/fluent-bit/etc/eh/parsers.yaml", sub_path = "flb-parsers" },
        { name = "flb-files", path = "/fluent-bit/etc/eh/lua/enterprise_hello.lua", sub_path = "flb-lua" },
      ]
      liveness_probe = { transport = "HTTP", port = 2020, path = "/api/v1/health" }
    }] : []
  }

  # App Service / Functions / Logic Apps Standard: Key Vault references for secret values
  app_settings = merge(
    local.env,
    { for k, id in local.secret_env : k => "@Microsoft.KeyVault(SecretUri=${id})" },
  )

  # Azure Container Instances: container group sidecar (azurerm_container_group container/volume blocks)
  aci_sidecar = local.uses_sidecar ? {
    container = {
      name                         = "fluent-bit"
      image                        = var.telemetry.fluentbit.sidecar_image
      cpu                          = var.sidecar_resources.cpu
      memory                       = 0.5
      commands                     = ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
      environment_variables        = local.sidecar_env
      secure_environment_variables = local.sidecar_secret_env # VALUES must be resolved by the caller from these secret ids
      volumes = [
        { name = "app-logs", mount_path = local.log_dir, empty_dir = true, secret = null },
        { name = "flb-config", mount_path = "/fluent-bit/etc/eh", empty_dir = false, secret = local.sidecar_files_ready ? {
          "fluent-bit.yaml" = base64encode(local.sidecar_config)
          "parsers.yaml"    = base64encode(var.telemetry.fluentbit.sidecar_parsers)
        } : null },
        { name = "flb-lua", mount_path = "/fluent-bit/etc/eh/lua", empty_dir = false, secret = local.sidecar_files_ready ? {
          "enterprise_hello.lua" = base64encode(var.telemetry.fluentbit.sidecar_lua)
        } : null },
      ]
    }
    app_volume_mounts = [{ name = "app-logs", mount_path = local.log_dir }]
  } : null

  # Kubernetes Deployment strategic-merge patch (AKS: Fluent Bit DaemonSet collects stdout; OTLP to node agent)
  k8s_labels = {
    "tags.datadoghq.com/env"     = local.s.env
    "tags.datadoghq.com/service" = local.s.service
    "tags.datadoghq.com/version" = local.s.version
    "team"                       = local.s.team
    "domain"                     = local.s.domain
    "tier"                       = local.s.tier
    "logs.datadoghq.com/source"  = local.dd_source
  }
  k8s_env = concat(
    var.architecture == "aks" ? [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }] : [],
    [for k in sort(keys(local.env)) : { name = k, value = local.env[k] }],
  )
  k8s_patch_object = {
    metadata = { labels = local.k8s_labels }
    spec = {
      template = {
        metadata = { labels = local.k8s_labels }
        spec = {
          containers = [{
            name = local.container
            env  = local.k8s_env
          }]
        }
      }
    }
  }
}
