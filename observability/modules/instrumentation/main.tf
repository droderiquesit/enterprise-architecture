# Instrumentation hook: computes everything an application's OWN deployment root needs to apply so that
# the workload emits telemetry along the authoritative path (ADR-0001 §10, README-transport.md):
#   env vars, Kubernetes patch, Container Apps sidecar patch, App Service/Functions app settings, ACI sidecar.
# Values only; secrets are Delinea DSV references (dsv://...), resolved at runtime by the workload itself
# (apps: hello_common / Hello.Common resolve env values starting with dsv://) or, for third-party containers
# (Fluent Bit sidecar), by the dsv-fetch helper writing an env-yaml file into a shared ephemeral volume.
# No resources, no providers, no Key Vault.
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

  # DSV runtime env contract (ADR-0001 section 14): how our app code and dsv-fetch reach DSV.
  dsv_env = merge(
    var.telemetry.secrets.tenant == null ? {} : { DSV_TENANT = var.telemetry.secrets.tenant },
    var.telemetry.secrets.tld == null ? {} : { DSV_TLD = var.telemetry.secrets.tld },
    {
      DSV_BASE_URL = var.telemetry.secrets.base_url
      DSV_AUTH     = var.telemetry.secrets.auth
    },
    var.identity_client_id == null ? {} : { AZURE_CLIENT_ID = var.identity_client_id },
  )

  # env vars whose VALUE is a DSV reference, resolved by the application at start-up (name -> dsv:// ref)
  secret_env = var.runtime != "browser" && local.otlp_target == "gateway" && var.telemetry.otlp.headers_ref != null ? {
    OTEL_EXPORTER_OTLP_HEADERS = var.telemetry.otlp.headers_ref
  } : {}

  # LOG_FILE_PATH only where a file tailer is the collector (sidecar, host service)
  env = merge(
    local.base_env,
    var.runtime == "browser" ? {} : local.dsv_env,
    local.secret_env,
    contains(["sidecar", "host"], local.log_route) && var.runtime != "browser" ? { LOG_FILE_PATH = var.log_file_path } : {},
    var.architecture == "functions" ? { AzureFunctionsJobHost__telemetryMode = "OpenTelemetry" } : {},
  )

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
  # Fluent Bit secrets: NAME -> dsv:// ref, written by dsv-fetch into the env-yaml file the sidecar config includes
  sidecar_secret_refs = local.sidecar_forward ? (
    var.telemetry.fluentbit.forward_shared_key_ref == null ? {} : { FLB_FORWARD_SHARED_KEY = var.telemetry.fluentbit.forward_shared_key_ref }
  ) : { DD_API_KEY = var.telemetry.api_key_ref }

  sidecar_config      = local.sidecar_forward ? var.telemetry.fluentbit.sidecar_forward_config : var.telemetry.fluentbit.sidecar_config
  sidecar_files_ready = local.sidecar_config != null && var.telemetry.fluentbit.sidecar_parsers != null && var.telemetry.fluentbit.sidecar_lua != null

  uses_sidecar = local.log_route == "sidecar" && var.runtime != "browser"
  needs_fetch  = local.uses_sidecar && length(local.sidecar_secret_refs) > 0

  secrets_dir   = replace(var.telemetry.secrets.env_file, "/\\/[^\\/]+$/", "")
  env_yaml_name = replace(var.telemetry.secrets.env_file, "/^.*\\//", "")

  # dsv-fetch command line (image entrypoint = dsv-fetch): one --map per secret, env-yaml for Fluent Bit
  fetch_args = concat(
    ["init", "--out", local.secrets_dir, "--format", "env-yaml", "--env-yaml-name", local.env_yaml_name],
    flatten([for k in sort(keys(local.sidecar_secret_refs)) : ["--map", "${k}=${local.sidecar_secret_refs[k]}"]]),
  )
  fetch_env = merge(local.dsv_env, { DSV_TIMEOUT_SECONDS = "10" })

  container_app_patch = {
    # Container Apps "secrets" carry ONLY the non-secret Fluent Bit config files (mounted as a Secret volume
    # because azurerm 5.9 has no config-file volume type); no Key Vault references, no secret values.
    secrets = local.uses_sidecar && local.sidecar_files_ready ? [
      { name = "flb-config", value = local.sidecar_config },
      { name = "flb-parsers", value = var.telemetry.fluentbit.sidecar_parsers },
      { name = "flb-lua", value = var.telemetry.fluentbit.sidecar_lua },
    ] : []
    volumes = local.uses_sidecar ? concat(
      [
        { name = "app-logs", storage_type = "EmptyDir" },
        { name = "flb-files", storage_type = "Secret" },
      ],
      local.needs_fetch ? [{ name = "dsv-secrets", storage_type = "EmptyDir" }] : [],
    ) : []
    # dsv-fetch runs before the sidecar starts and writes the env-yaml file (mode 0400) into the
    # replica-scoped EmptyDir. Requires managed identity for init containers: workload-profiles environment,
    # Consumption profile (Microsoft Learn: init containers cannot use managed identities in consumption-only
    # environments or on dedicated workload profiles).
    init_containers = local.needs_fetch ? [{
      name          = "dsv-fetch"
      image         = var.telemetry.secrets.fetch_image
      cpu           = var.fetch_resources.cpu
      memory        = var.fetch_resources.memory
      command       = null
      args          = local.fetch_args
      env           = [for k in sort(keys(local.fetch_env)) : { name = k, value = local.fetch_env[k], secret_name = null }]
      volume_mounts = [{ name = "dsv-secrets", path = local.secrets_dir, sub_path = null }]
    }] : []
    # Same reader as a regular REFRESHER container, for Dedicated workload profiles / consumption-only environments
    # where init containers get no managed identity: writes the file, then re-fetches every refresh_s seconds; the
    # sidecar fails fast until the file exists and is restarted by the platform.
    refresher_containers = local.needs_fetch ? [{
      name          = "dsv-fetch"
      image         = var.telemetry.secrets.fetch_image
      cpu           = var.fetch_resources.cpu
      memory        = var.fetch_resources.memory
      command       = ["/usr/bin/python3.13", "-I", "-c", local.aci_fetch_stub]
      args          = local.fetch_args
      env           = [for k in sort(keys(local.fetch_env)) : { name = k, value = local.fetch_env[k], secret_name = null }]
      volume_mounts = [{ name = "dsv-secrets", path = local.secrets_dir, sub_path = null }]
    }] : []
    app_container = {
      name          = local.container
      env           = [for k in sort(keys(local.env)) : { name = k, value = local.env[k], secret_name = null }]
      volume_mounts = local.uses_sidecar ? [{ name = "app-logs", path = local.log_dir, sub_path = null }] : []
    }
    sidecars = local.uses_sidecar ? [{
      name   = "fluent-bit"
      image  = var.telemetry.fluentbit.sidecar_image
      cpu    = var.sidecar_resources.cpu
      memory = var.sidecar_resources.memory
      args   = ["-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
      env    = [for k in sort(keys(local.sidecar_env)) : { name = k, value = local.sidecar_env[k], secret_name = null }]
      volume_mounts = concat(
        [
          { name = "app-logs", path = local.log_dir, sub_path = null },
          { name = "flb-files", path = "/fluent-bit/etc/eh/fluent-bit.yaml", sub_path = "flb-config" },
          { name = "flb-files", path = "/fluent-bit/etc/eh/parsers.yaml", sub_path = "flb-parsers" },
          { name = "flb-files", path = "/fluent-bit/etc/eh/lua/enterprise_hello.lua", sub_path = "flb-lua" },
        ],
        local.needs_fetch ? [{ name = "dsv-secrets", path = local.secrets_dir, sub_path = null }] : [],
      )
      liveness_probe = { transport = "HTTP", port = 2020, path = "/api/v1/health" }
    }] : []
  }

  # App Service / Functions / Logic Apps Standard: plain app settings. Secret settings carry the dsv://
  # reference as their VALUE; the app resolves it at start-up with its managed identity (DSV_* settings).
  app_settings = local.env

  # Azure Container Instances: ACI init containers cannot use managed identities (Microsoft Learn,
  # "Run an init container"), so dsv-fetch runs as a regular REFRESHER container: it writes the env-yaml
  # file, then re-fetches every refresh_s seconds (rotation pick-up; retries every 30 s on failure). Fluent Bit
  # fails fast while the include file is missing and is restarted by the group's restart policy.
  # image: distroless python (ENTRYPOINT python3.13 -I /opt/dsv-fetch/dsv_fetch.py, no shell) -> override with an
  # inline python loop that re-runs the same script
  aci_fetch_stub = "import subprocess,sys,time\nwhile True:\n    rc = subprocess.call([sys.executable, '-I', '/opt/dsv-fetch/dsv_fetch.py'] + sys.argv[1:])\n    time.sleep(${var.fetch_resources.refresh_s} if rc == 0 else 30)\n"
  aci_sidecar = local.uses_sidecar ? {
    container = {
      name                         = "fluent-bit"
      image                        = var.telemetry.fluentbit.sidecar_image
      cpu                          = var.sidecar_resources.cpu
      memory                       = 0.5
      commands                     = ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
      environment_variables        = local.sidecar_env
      secure_environment_variables = {}
      volumes = concat(
        [
          { name = "app-logs", mount_path = local.log_dir, empty_dir = true, secret = null },
          { name = "flb-config", mount_path = "/fluent-bit/etc/eh", empty_dir = false, secret = local.sidecar_files_ready ? {
            "fluent-bit.yaml" = base64encode(local.sidecar_config)
            "parsers.yaml"    = base64encode(var.telemetry.fluentbit.sidecar_parsers)
          } : null },
          { name = "flb-lua", mount_path = "/fluent-bit/etc/eh/lua", empty_dir = false, secret = local.sidecar_files_ready ? {
            "enterprise_hello.lua" = base64encode(var.telemetry.fluentbit.sidecar_lua)
          } : null },
        ],
        local.needs_fetch ? [{ name = "dsv-secrets", mount_path = local.secrets_dir, empty_dir = true, secret = null }] : [],
      )
    }
    fetcher = local.needs_fetch ? {
      name                  = "dsv-fetch"
      image                 = var.telemetry.secrets.fetch_image
      cpu                   = var.fetch_resources.aci_cpu
      memory                = var.fetch_resources.aci_mem
      commands              = concat(["/usr/bin/python3.13", "-I", "-c", local.aci_fetch_stub], local.fetch_args)
      environment_variables = local.fetch_env
      volumes               = [{ name = "dsv-secrets", mount_path = local.secrets_dir, empty_dir = true, secret = null }]
    } : null
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
