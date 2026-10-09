# Instrumentation hook: computes everything an application's OWN deployment root needs to apply so that
# the workload emits telemetry along the authoritative path (ADR-0001 §10, README-transport.md):
#   env vars, Kubernetes patch, Container Apps sidecar patch, App Service/Functions app settings, ACI sidecar.
# Values only; secrets are Delinea DSV references (dsv://...), resolved at runtime by the workload itself
# (apps: hello_common / Hello.Common resolve env values starting with dsv://) or, for third-party containers
# (Fluent Bit sidecar), by the dsv-fetch helper writing an env-yaml file into a shared ephemeral volume.
# No resources, no providers, no Key Vault.
module "tags" {
  source = "../tagging"
  policy = var.tag_policy
  identity = merge(var.service.extra, {
    env         = var.service.env
    service     = var.service.service
    version     = var.service.version
    team        = var.service.team
    owner       = var.service.owner
    domain      = var.service.domain
    tier        = var.service.tier
    application = var.service.application
    region      = var.service.region
    managed_by  = var.service.managed_by
    cost_center = var.service.cost_center
    component   = var.service.component
  })
  extra_tags = var.extra_tags
}

# Fleet policy (config/fleet-policy.yaml unless overridden): APM library, profiler, DSM, DBM propagation, log pipeline.
# Lab-wide switches may arrive through the transport contract's env map "fleet" (EH_LOG_PIPELINE, EH_APM_MODE,
# EH_PROFILING_ENABLED); explicit module inputs win.
module "fleet" {
  source       = "../fleet-policy"
  policy       = var.fleet_policy
  architecture = var.architecture
  runtime      = var.runtime
  os_type      = var.os_type
  env          = module.tags.unified.env
  overrides = merge(
    local.contract_fleet,
    var.apm == null ? {} : { apm = var.apm },
    var.profiling == null ? {} : { profiling = var.profiling },
  )
}

locals {
  container = coalesce(var.container_name, var.service.service)

  fleet_env = lookup(var.telemetry.env, "fleet", {})
  contract_fleet = merge(
    lookup(local.fleet_env, "EH_LOG_PIPELINE", "") == "" ? {} : { log_pipeline = local.fleet_env["EH_LOG_PIPELINE"] },
    lookup(local.fleet_env, "EH_APM_MODE", "") == "" ? {} : { apm = { mode = local.fleet_env["EH_APM_MODE"] } },
    lookup(local.fleet_env, "EH_PROFILING_ENABLED", "") == "" ? {} : { profiling = { enabled = local.fleet_env["EH_PROFILING_ENABLED"] == "true" } },
  )

  apm       = module.fleet.apm
  profiling = module.fleet.profiling
  dd_mode   = local.apm.mode == "datadog"
  otel_mode = local.apm.mode == "otel"

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
  # daemonset / host routes: the node Datadog Agent (Observability Pipelines mode) or Fluent Bit collects
  log_collector = contains(["daemonset", "host"], local.log_route) ? (module.fleet.node_collector == "agent" ? "datadog-agent" : "fluent-bit") : (
    local.log_route == "sidecar" ? "fluent-bit-sidecar" : "diagnostic-settings"
  )

  # where OTLP goes (otel mode): node-local Agent (AKS DaemonSet hostPort / VM agent) or the OTel gateway
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

  # One tag contract for every path (modules/tagging): DD_* / DD_TAGS, OTEL_RESOURCE_ATTRIBUTES, Fluent Bit
  # ddtags, Kubernetes labels + ad.datadoghq.com/tags, RUM global context and Azure resource tags all carry the
  # same normalised values.
  resource_attributes = merge(
    module.tags.otel_resource_attributes,
    {
      "cloud.provider" = "azure"
      "cloud.platform" = local.cloud_platform
    },
    var.extra_resource_attributes,
  )
  otel_resource_attributes = join(",", [for k in sort(keys(local.resource_attributes)) : "${k}=${replace(replace(local.resource_attributes[k], ",", "%2C"), "=", "%3D")}"])

  dd_tags = module.tags.dd_tags
  u       = module.tags.unified

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

  # ---------------------------------------------------------------- Datadog tracer (apm.mode = datadog)
  # agent_gateway: the tracer in the image sends to the telemetry transport's in-VNet Datadog Agent APM gateway
  # (contract env.apm_gateway.DD_TRACE_AGENT_URL); the API key never reaches the workload.
  gateway_url   = lookup(lookup(var.telemetry.env, "apm_gateway", {}), "DD_TRACE_AGENT_URL", "")
  gateway_ready = local.apm.method != "agent_gateway" || local.gateway_url != ""
  # .NET tracer location: SSI injects it; containers install the dd-trace-dotnet tarball at /opt/datadog; App Service
  # and Functions ship the Datadog.Trace.Bundle NuGet package in the app (<wwwroot>/datadog).
  tracer_home = coalesce(var.dotnet_tracer_home, contains(["appservice", "functions"], var.architecture) ? (
    var.os_type == "windows" ? "C:\\home\\site\\wwwroot\\datadog" : "/home/site/wwwroot/datadog"
  ) : "/opt/datadog")
  clr_env = var.runtime != "dotnet" || !contains(["agent_gateway", "serverless_init"], coalesce(local.apm.method, "none")) ? {} : (
    var.os_type == "windows" ? {
      CORECLR_ENABLE_PROFILING = "1"
      CORECLR_PROFILER         = "{846F5F1C-F9AE-4B07-969E-05C26BC060D8}"
      CORECLR_PROFILER_PATH_64 = "${local.tracer_home}\\win-x64\\Datadog.Trace.ClrProfiler.Native.dll"
      DD_DOTNET_TRACER_HOME    = local.tracer_home
      } : {
      CORECLR_ENABLE_PROFILING = "1"
      CORECLR_PROFILER         = "{846F5F1C-F9AE-4B07-969E-05C26BC060D8}"
      CORECLR_PROFILER_PATH    = "${local.tracer_home}/linux-x64/Datadog.Trace.ClrProfiler.Native.so"
      DD_DOTNET_TRACER_HOME    = local.tracer_home
      LD_PRELOAD               = "${local.tracer_home}/linux-x64/Datadog.Linux.ApiWrapper.x64.so"
    }
  )
  datadog_env = !local.dd_mode ? {} : merge(
    module.fleet.apm_env,
    local.clr_env,
    local.apm.method == "agent_gateway" && local.gateway_url != "" ? { DD_TRACE_AGENT_URL = local.gateway_url } : {},
    var.architecture == "aks" ? {} : { DD_SITE = var.telemetry.datadog_site },
  )

  # ---------------------------------------------------------------- OpenTelemetry SDK (apm.mode = otel)
  otel_env = !local.otel_mode ? {} : merge(local.runtime_env[var.runtime], {
    TELEMETRY_SDK               = "otel"
    OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
    OTEL_EXPORTER_OTLP_PROTOCOL = local.protocol
    OTEL_TRACES_SAMPLER         = "parentbased_traceidratio"
    OTEL_TRACES_SAMPLER_ARG     = tostring(var.trace_sample_ratio)
    OTEL_TRACES_EXPORTER        = "otlp"
    OTEL_METRICS_EXPORTER       = "otlp"
    # application logs travel through the log pipeline only (no OTLP logs -> no duplicates)
    OTEL_LOGS_EXPORTER = "none"
    OTEL_PROPAGATORS   = "tracecontext,baggage"
  })
  none_env = local.apm.mode == "none" && var.runtime != "browser" ? {
    TELEMETRY_SDK      = "none"
    OTEL_SDK_DISABLED  = "true"
    OTEL_LOGS_EXPORTER = "none"
  } : {}

  base_env = var.runtime == "browser" ? {
    DD_SITE    = var.telemetry.datadog_site
    DD_ENV     = local.u.env
    DD_SERVICE = local.u.service
    DD_VERSION = local.u.version
    } : merge(local.contract_env, {
      DD_ENV     = local.u.env
      DD_SERVICE = local.u.service
      DD_VERSION = local.u.version
      # extra policy tags (DD_TAGS for Datadog tracers/profilers, OTEL_RESOURCE_ATTRIBUTES for OTel SDKs)
      DD_TAGS                  = module.tags.dd_tags_extra
      OTEL_SERVICE_NAME        = local.u.service
      OTEL_RESOURCE_ATTRIBUTES = local.otel_resource_attributes
  }, local.otel_env, local.datadog_env, local.none_env, local.profiling.env)

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
  secret_env = var.runtime != "browser" && local.otel_mode && local.otlp_target == "gateway" && var.telemetry.otlp.headers_ref != null ? {
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
      FLB_DD_SERVICE = local.u.service
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
    sidecars = concat(local.uses_sidecar ? [{
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
    }] : [], local.serverless_init_sidecar)
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

  # Kubernetes Deployment strategic-merge patch. Logs: the node Datadog Agent (-> Observability Pipelines Worker) or
  # the Fluent Bit DaemonSet collects stdout. Traces: SSI-injected Datadog tracer (admission controller) or OTLP.
  k8s_labels = merge(
    module.tags.k8s_labels,
    { "logs.datadoghq.com/source" = local.dd_source },
    local.apm.method == "ssi_kubernetes" ? { "admission.datadoghq.com/enabled" = "true" } : {},
  )
  k8s_annotations = merge(
    module.tags.k8s_annotations,
    # Agent log collection: source/service of the container's stdout (the Agent then ships to the OP Worker)
    local.log_collector == "datadog-agent" ? { "ad.datadoghq.com/${local.container}.logs" = jsonencode([{ source = local.dd_source, service = local.u.service }]) } : {},
  )

  # ---------------------------------------------------------------- Datadog serverless-init sidecar (ACA, opt-in)
  # Datadog's Container Apps sidecar pattern. serverless-init 1.10.4 reads DD_API_KEY only as a plain value (it does
  # not resolve ENC[] secret backends - verified locally), so the key must be an ACA secret the application owner
  # maintains (var.serverless_init.api_key_secret_name): a documented exception to the DSV-only rule. Logs stay on
  # the Fluent Bit sidecar (DD_LOGS_ENABLED=false) - no double collection.
  serverless_init_sidecar = local.apm.method == "serverless_init" && var.runtime != "browser" ? [{
    name   = "datadog"
    image  = var.serverless_init.image
    cpu    = var.serverless_init.cpu
    memory = var.serverless_init.memory
    args   = []
    env = concat(
      [for k, v in {
        DD_SITE                  = var.telemetry.datadog_site
        DD_ENV                   = local.u.env
        DD_SERVICE               = local.u.service
        DD_VERSION               = local.u.version
        DD_TAGS                  = module.tags.dd_tags_extra
        DD_LOGS_ENABLED          = "false"
        DD_AZURE_SUBSCRIPTION_ID = coalesce(var.serverless_init.subscription_id, "unset")
        DD_AZURE_RESOURCE_GROUP  = coalesce(var.serverless_init.resource_group, "unset")
      } : { name = k, value = v, secret_name = null }],
      [{ name = "DD_API_KEY", value = null, secret_name = var.serverless_init.api_key_secret_name }],
    )
    volume_mounts  = []
    liveness_probe = null
  }] : []
  k8s_env = concat(
    var.architecture == "aks" ? [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }] : [],
    [for k in sort(keys(local.env)) : { name = k, value = local.env[k] }],
  )
  k8s_patch_object = {
    metadata = { labels = local.k8s_labels }
    spec = {
      template = {
        metadata = { labels = local.k8s_labels, annotations = local.k8s_annotations }
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
