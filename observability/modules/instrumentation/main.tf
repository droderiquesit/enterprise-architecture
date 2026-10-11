# Pure instrumentation hook (no resources): env, Kubernetes / Container Apps / ACI patches and app settings an
# application's own deployment root applies. Secrets are dsv:// references only, resolved at run time by the app or
# by the dsv-fetch binary in the Datadog / Fluent Bit containers.
module "tags" {
  source     = "../tagging"
  policy     = var.tag_policy
  identity   = merge(var.service.extra, { for k, v in var.service : k => v if k != "extra" })
  extra_tags = var.extra_tags
}

# Contract env map "fleet" (EH_LOG_PIPELINE, EH_APM_MODE, EH_PROFILING_ENABLED) carries lab-wide switches; explicit
# module inputs win.
module "fleet" {
  source       = "../fleet-policy"
  policy       = var.fleet_policy
  architecture = var.architecture
  runtime      = var.runtime
  os_type      = var.os_type
  env          = module.tags.unified.env
  overrides = merge(
    local.contract_fleet,
    { apm = merge(try(local.contract_fleet.apm, {}), var.apm == null ? {} : var.apm) },
    { profiling = merge(try(local.contract_fleet.profiling, {}), var.profiling == null ? {} : var.profiling) },
    var.logs == null ? {} : { logs = var.logs },
  )
}

locals {
  container = coalesce(var.container_name, var.service.service)

  fleet_env = lookup(var.telemetry.env, "fleet", {})
  # A per-architecture apm.mode of the policy (functions/appservice = otel, ...) wins over the contract's EH_APM_MODE.
  policy_doc     = [for p in [var.fleet_policy, yamldecode(file("${path.module}/../../config/fleet-policy.yaml"))] : p if p != null][0]
  arch_apm_mode  = try(local.policy_doc.architectures[var.architecture].apm.mode, null)
  contract_apm_m = lookup(local.fleet_env, "EH_APM_MODE", "") == "" || local.arch_apm_mode != null ? {} : { apm = { mode = local.fleet_env["EH_APM_MODE"] } }
  contract_fleet = merge(
    lookup(local.fleet_env, "EH_LOG_PIPELINE", "") == "" ? {} : { log_pipeline = local.fleet_env["EH_LOG_PIPELINE"] },
    local.contract_apm_m,
    lookup(local.fleet_env, "EH_PROFILING_ENABLED", "") == "" ? {} : { profiling = { enabled = local.fleet_env["EH_PROFILING_ENABLED"] == "true" } },
  )

  apm       = module.fleet.apm
  profiling = module.fleet.profiling
  dd_mode   = local.apm.mode == "datadog"
  otel_mode = local.apm.mode == "otel"

  collector = var.runtime == "browser" ? "none" : module.fleet.log_collector
  log_route = local.collector == "azure" ? "eventhub" : {
    aks        = "daemonset"
    vm         = "host"
    vmss       = "host"
    aca        = "sidecar"
    aci        = "sidecar"
    appservice = "eventhub"
    functions  = "eventhub"
    logicapp   = "eventhub"
  }[var.architecture]
  log_collector = lookup({
    agent              = "datadog-agent"
    agent_sidecar      = "datadog-agent-sidecar"
    serverless_init    = "serverless-init"
    azure              = "diagnostic-settings"
    fluent_bit         = "fluent-bit"
    fluent_bit_sidecar = "fluent-bit-sidecar"
  }, local.collector, "none")
  # a file tailer collects LOG_FILE_PATH (shared volume on ACA / ACI, host file on VMs)
  file_tail = contains(["agent_sidecar", "serverless_init", "fluent_bit_sidecar"], local.collector) || local.log_route == "host"

  op_mode     = module.fleet.log_pipeline == "observability_pipelines"
  op_logs_url = try(var.telemetry.aggregator.agent_logs_url, null)

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

  contract_env = merge(lookup(var.telemetry.env, "common", {}), lookup(var.telemetry.env, var.runtime, {}))

  # ---------------------------------------------------------------- Datadog tracer (apm.mode = datadog)
  gateway_url   = lookup(lookup(var.telemetry.env, "apm_gateway", {}), "DD_TRACE_AGENT_URL", "")
  gateway_ready = local.apm.method != "agent_gateway" || local.gateway_url != ""
  # .NET tracer: dd-trace-dotnet tarball at /opt/datadog in containers, Datadog.Trace.Bundle in <wwwroot>/datadog on App Service.
  tracer_home = coalesce(var.dotnet_tracer_home, contains(["appservice", "functions"], var.architecture) ? (
    var.os_type == "windows" ? "C:\\home\\site\\wwwroot\\datadog" : "/home/site/wwwroot/datadog"
  ) : "/opt/datadog")
  clr_env = var.runtime != "dotnet" || !contains(["agent_gateway", "serverless_init", "agent_sidecar"], coalesce(local.apm.method, "none")) ? {} : merge(
    {
      CORECLR_ENABLE_PROFILING = "1"
      CORECLR_PROFILER         = "{846F5F1C-F9AE-4B07-969E-05C26BC060D8}"
      DD_DOTNET_TRACER_HOME    = local.tracer_home
    },
    var.os_type == "windows" ? {
      CORECLR_PROFILER_PATH_64 = "${local.tracer_home}\\win-x64\\Datadog.Trace.ClrProfiler.Native.dll"
      } : {
      CORECLR_PROFILER_PATH = "${local.tracer_home}/linux-x64/Datadog.Trace.ClrProfiler.Native.so"
      LD_PRELOAD            = "${local.tracer_home}/linux-x64/Datadog.Linux.ApiWrapper.x64.so"
    },
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
    OTEL_LOGS_EXPORTER          = "none" # logs travel the log pipeline only (no duplicates)
    OTEL_PROPAGATORS            = "tracecontext,baggage"
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
    } : merge(
    # datadog mode: no OTEL_* at all (the library maps OTEL_RESOURCE_ATTRIBUTES to DD_TAGS -> duplicate tags)
    { for k, v in local.contract_env : k => v if !(local.dd_mode && startswith(k, "OTEL_")) },
    {
      DD_ENV     = local.u.env
      DD_SERVICE = local.u.service
      DD_VERSION = local.u.version
      DD_TAGS    = module.tags.dd_tags_extra
    },
    local.dd_mode ? {} : {
      OTEL_SERVICE_NAME        = local.u.service
      OTEL_RESOURCE_ATTRIBUTES = local.otel_resource_attributes
    },
  local.otel_env, local.datadog_env, local.none_env, local.profiling.env)

  # DSV runtime env contract (ADR-0001 §14) for app code and dsv-fetch.
  dsv_env = merge(
    var.telemetry.secrets.tenant == null ? {} : { DSV_TENANT = var.telemetry.secrets.tenant },
    var.telemetry.secrets.tld == null ? {} : { DSV_TLD = var.telemetry.secrets.tld },
    {
      DSV_BASE_URL = var.telemetry.secrets.base_url
      DSV_AUTH     = var.telemetry.secrets.auth
    },
    var.identity_client_id == null ? {} : { AZURE_CLIENT_ID = var.identity_client_id },
  )

  secret_env = var.runtime != "browser" && local.otel_mode && local.otlp_target == "gateway" && var.telemetry.otlp.headers_ref != null ? {
    OTEL_EXPORTER_OTLP_HEADERS = var.telemetry.otlp.headers_ref
  } : {}

  env = merge(
    local.base_env,
    var.runtime == "browser" ? {} : local.dsv_env,
    local.secret_env,
    local.file_tail && var.runtime != "browser" ? { LOG_FILE_PATH = var.log_file_path } : {},
    var.architecture == "functions" ? { AzureFunctionsJobHost__telemetryMode = "OpenTelemetry" } : {},
  )

  # ---------------------------------------------------------------- shared by the sidecar paths (aca / aci)
  log_dir = replace(var.log_file_path, "/\\/[^\\/]+$/", "")
  dd_source = {
    dotnet  = "csharp"
    python  = "python"
    node    = "nodejs"
    java    = "java"
    browser = "browser"
  }[var.runtime]
  fleet_agent = module.fleet.agent

  # An identity-free init container copies the dsv-fetch binary into a shared volume (init containers get no managed
  # identity on ACI and Container Apps Dedicated profiles); the Datadog container then reads DSV with its own identity.
  fetch_bin_src = "/opt/dsv-fetch/dsv-fetch"
  dsv_bin_dir   = "/eh/dsv-bin"
  dsv_bin       = "${local.dsv_bin_dir}/dsv-fetch"
  fetch_env     = merge(local.dsv_env, { DSV_TIMEOUT_SECONDS = "10" })
  ignore_res    = module.fleet.agent_apm_ignore_resources

  # ---------------------------------------------------------------- Fluent Bit sidecar (fluent_bit_direct fallback)
  intake_host     = coalesce(var.telemetry.fluentbit.logs_intake_host, "http-intake.logs.${var.telemetry.datadog_site}")
  sidecar_forward = var.telemetry.fluentbit.sidecar_mode == "forward"

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
  sidecar_secret_refs = local.sidecar_forward ? (
    var.telemetry.fluentbit.forward_shared_key_ref == null ? {} : { FLB_FORWARD_SHARED_KEY = var.telemetry.fluentbit.forward_shared_key_ref }
  ) : { DD_API_KEY = var.telemetry.api_key_ref }

  sidecar_config      = local.sidecar_forward ? var.telemetry.fluentbit.sidecar_forward_config : var.telemetry.fluentbit.sidecar_config
  sidecar_files_ready = local.sidecar_config != null && var.telemetry.fluentbit.sidecar_parsers != null && var.telemetry.fluentbit.sidecar_lua != null

  uses_sidecar = local.collector == "fluent_bit_sidecar"
  needs_fetch  = local.uses_sidecar && length(local.sidecar_secret_refs) > 0

  secrets_dir   = replace(var.telemetry.secrets.env_file, "/\\/[^\\/]+$/", "")
  env_yaml_name = replace(var.telemetry.secrets.env_file, "/^.*\\//", "")

  # The refresher variant (regular container on ACI / Container Apps Dedicated profiles) re-fetches every refresh_s.
  fetch_args = concat(
    ["init", "--out", local.secrets_dir, "--format", "env-yaml", "--env-yaml-name", local.env_yaml_name],
    flatten([for k in sort(keys(local.sidecar_secret_refs)) : ["--map", "${k}=${local.sidecar_secret_refs[k]}"]]),
  )
  refresh_args = concat(local.fetch_args, ["--refresh-seconds", tostring(var.fetch_resources.refresh_s), "--retry-seconds", "30"])

  # ---------------------------------------------------------------- Datadog serverless-init sidecar (ACA, default)
  # In sidecar mode serverless-init cannot read another container's stdout, so it tails DD_SERVERLESS_LOG_PATH.
  # It reads DD_API_KEY only from its environment (no ENC[] backend), so the start command fetches the key into the
  # container's own /tmp, sources and truncates it, then execs /datadog-init (/bin/sh, no coreutils in the image).
  uses_serverless_init = var.architecture == "aca" && var.runtime != "browser" && (local.apm.method == "serverless_init" || local.collector == "serverless_init")
  si_logs              = local.collector == "serverless_init" && (!local.op_mode || local.op_logs_url != null)
  si_image             = try(coalesce(try(var.serverless_init.image, null), module.fleet.serverless_init.image), null)
  si_tmp               = "/tmp/dsv-fetch"
  si_start = join(" && ", [
    "${local.dsv_bin} init --out ${local.si_tmp} --format dotenv --dotenv-name serverless-init.env --map DD_API_KEY=${var.telemetry.api_key_ref}",
    "set -a", ". ${local.si_tmp}/serverless-init.env", "set +a", ": > ${local.si_tmp}/serverless-init.env", "exec /datadog-init",
  ])
  si_env = merge(
    local.fetch_env,
    {
      DD_SITE                  = var.telemetry.datadog_site
      DD_ENV                   = local.u.env
      DD_SERVICE               = local.u.service
      DD_VERSION               = local.u.version
      DD_TAGS                  = module.tags.dd_tags_extra
      DD_SOURCE                = local.dd_source
      DD_LOGS_ENABLED          = tostring(local.si_logs)
      DD_AZURE_SUBSCRIPTION_ID = coalesce(try(var.serverless_init.subscription_id, null), "unset")
      DD_AZURE_RESOURCE_GROUP  = coalesce(try(var.serverless_init.resource_group, null), "unset")
    },
    length(local.ignore_res) == 0 ? {} : { DD_APM_IGNORE_RESOURCES = join(",", local.ignore_res) },
    local.si_logs ? { DD_SERVERLESS_LOG_PATH = var.log_file_path } : {},
    local.si_logs && local.op_mode ? {
      DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED = "true"
      DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL     = local.op_logs_url
    } : {},
  )
  serverless_init_sidecar = [for _ in(local.uses_serverless_init ? [1] : []) : {
    name    = "datadog"
    image   = local.si_image
    cpu     = coalesce(try(var.serverless_init.cpu, null), module.fleet.serverless_init.cpu)
    memory  = coalesce(try(var.serverless_init.memory, null), module.fleet.serverless_init.memory)
    command = ["/bin/sh", "-c", local.si_start]
    args    = []
    env     = [for k in sort(keys(local.si_env)) : { name = k, value = local.si_env[k], secret_name = null }]
    volume_mounts = concat(
      [{ name = "dsv-bin", path = local.dsv_bin_dir, sub_path = null }],
      local.collector == "serverless_init" ? [{ name = "app-logs", path = local.log_dir, sub_path = null }] : [],
    )
    liveness_probe = { transport = "TCP", port = 8126, path = null }
  }]

  # ---------------------------------------------------------------- Container Apps patch
  aca_file_logs = var.architecture == "aca" && contains(["serverless_init", "fluent_bit_sidecar"], local.collector)
  # needs_identity = true entries (Fluent Bit fetch) run as init containers on the Consumption profile only and as
  # refresher containers elsewhere: init containers there get no managed identity.
  aca_inits = concat(
    local.uses_serverless_init ? [{
      name           = "dsv-fetch-install"
      image          = var.telemetry.secrets.fetch_image
      cpu            = var.fetch_resources.cpu
      memory         = var.fetch_resources.memory
      command        = null
      args           = ["install", "--dest", local.dsv_bin]
      env            = []
      volume_mounts  = [{ name = "dsv-bin", path = local.dsv_bin_dir, sub_path = null }]
      needs_identity = false
    }] : [],
    local.needs_fetch ? [{
      name           = "dsv-fetch"
      image          = var.telemetry.secrets.fetch_image
      cpu            = var.fetch_resources.cpu
      memory         = var.fetch_resources.memory
      command        = null
      args           = local.fetch_args
      env            = [for k in sort(keys(local.fetch_env)) : { name = k, value = local.fetch_env[k], secret_name = null }]
      volume_mounts  = [{ name = "dsv-secrets", path = local.secrets_dir, sub_path = null }]
      needs_identity = true
    }] : [],
  )

  container_app_patch = {
    # Non-secret Fluent Bit config files, mounted as a Secret volume (azurerm 5.9 has no config-file volume type).
    secrets = local.uses_sidecar && local.sidecar_files_ready ? [
      { name = "flb-config", value = local.sidecar_config },
      { name = "flb-parsers", value = var.telemetry.fluentbit.sidecar_parsers },
      { name = "flb-lua", value = var.telemetry.fluentbit.sidecar_lua },
    ] : []
    volumes = concat(
      local.aca_file_logs ? [{ name = "app-logs", storage_type = "EmptyDir" }] : [],
      local.uses_sidecar ? [{ name = "flb-files", storage_type = "Secret" }] : [],
      local.needs_fetch ? [{ name = "dsv-secrets", storage_type = "EmptyDir" }] : [],
      local.uses_serverless_init ? [{ name = "dsv-bin", storage_type = "EmptyDir" }] : [],
    )
    init_containers = local.aca_inits
    # the sidecar fails fast until the refresher has written the file and is restarted by the platform
    refresher_containers = [for c in local.aca_inits : merge(c, { args = local.refresh_args }) if c.needs_identity]
    app_container = {
      name          = local.container
      env           = [for k in sort(keys(local.env)) : { name = k, value = local.env[k], secret_name = null }]
      volume_mounts = local.aca_file_logs ? [{ name = "app-logs", path = local.log_dir, sub_path = null }] : []
    }
    # tuples: the Fluent Bit and serverless-init sidecars have different shapes
    sidecars = concat([for _ in(local.uses_sidecar && var.architecture == "aca" ? [1] : []) : {
      name    = "fluent-bit"
      image   = var.telemetry.fluentbit.sidecar_image
      cpu     = var.sidecar_resources.cpu
      memory  = var.sidecar_resources.memory
      command = null
      args    = ["-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
      env     = [for k in sort(keys(local.sidecar_env)) : { name = k, value = local.sidecar_env[k], secret_name = null }]
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
    }], local.serverless_init_sidecar)
  }


  # ---------------------------------------------------------------- Datadog Agent sidecar (ACI, default)
  # The group shares one network namespace: traces / DogStatsD on localhost only (non-local traffic off). Logs: the
  # Agent tails LOG_FILE_PATH (buffers across restarts; no network log handler needed in the apps). The start command
  # re-installs dsv-fetch as root 0500, which the Agent's secret-backend permission check requires.
  uses_agent_sidecar = var.architecture == "aci" && var.runtime != "browser" && (local.apm.method == "agent_sidecar" || local.collector == "agent_sidecar")
  agent_logs         = local.collector == "agent_sidecar" && (!local.op_mode || local.op_logs_url != null)
  agent_apm          = local.apm.method == "agent_sidecar"
  agent_image        = try(coalesce(var.agent_sidecar.image, module.fleet.agent_sidecar.image), null)
  agent_hostname     = coalesce(var.agent_sidecar.hostname, "${local.u.service}-${local.u.env}")
  agent_cfg_dir      = "/eh/agent"
  agent_datadog_yaml = yamlencode(merge(
    {
      api_key      = "ENC[${var.telemetry.api_key_ref}]"
      site         = var.telemetry.datadog_site
      hostname     = local.agent_hostname
      env          = local.u.env
      tags         = compact(split(",", module.tags.dd_tags_extra))
      logs_enabled = local.agent_logs
      logs_config  = { container_collect_all = false }
      apm_config = {
        enabled               = local.agent_apm
        apm_non_local_traffic = false
        ignore_resources      = local.ignore_res
      }
      use_dogstatsd               = true
      dogstatsd_non_local_traffic = false
      remote_configuration        = { enabled = try(local.fleet_agent.remote_configuration, true) }
      process_config              = { process_collection = { enabled = try(local.fleet_agent.process_collection, false) } }
      enable_metadata_collection  = true
      health_port                 = 5555
      secret_backend_command      = "/opt/dsv-fetch/dsv-fetch"
      secret_backend_arguments    = ["agent-backend", "--config", "${local.agent_cfg_dir}/dsv.json"]
      secret_backend_timeout      = 30
      secret_refresh_interval     = 3600 # DSV key rotation without a restart
    },
  ))
  # full policy tag set on the log source: the Agent does not attach host tags to logs
  agent_logs_conf = yamlencode({ logs = [{ type = "file", path = var.log_file_path, service = local.u.service, source = local.dd_source, tags = compact(split(",", local.dd_tags)) }] })
  agent_dsv_json  = jsonencode(local.fetch_env)
  agent_start = join(" && ", concat(
    [
      "${local.dsv_bin} install --dest /opt/dsv-fetch/dsv-fetch",
      "cp ${local.agent_cfg_dir}/datadog.yaml /etc/datadog-agent/datadog.yaml",
    ],
    local.agent_logs ? ["mkdir -p /etc/datadog-agent/conf.d/app.d", "cp ${local.agent_cfg_dir}/app-logs.yaml /etc/datadog-agent/conf.d/app.d/conf.yaml"] : [],
    ["exec /bin/entrypoint.sh"],
  ))
  agent_env = merge(
    {
      DD_API_KEY      = "ENC[${var.telemetry.api_key_ref}]" # the image's init script requires a non-empty value
      DD_HOSTNAME     = local.agent_hostname
      DD_LOGS_ENABLED = tostring(local.agent_logs)
    },
    local.agent_logs && local.op_mode ? {
      DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED = "true"
      DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL     = local.op_logs_url
    } : {},
  )
  aci_file_logs = var.architecture == "aci" && contains(["agent_sidecar", "fluent_bit_sidecar"], local.collector)
  aci_agent = [for _ in(local.uses_agent_sidecar ? [1] : []) : {
    name                         = "datadog-agent"
    image                        = local.agent_image
    cpu                          = coalesce(var.agent_sidecar.cpu, module.fleet.agent_sidecar.cpu)
    memory                       = coalesce(var.agent_sidecar.memory_gb, module.fleet.agent_sidecar.memory_gb)
    commands                     = ["/bin/sh", "-c", local.agent_start]
    environment_variables        = local.agent_env
    secure_environment_variables = {}
    volumes = concat(
      [
        { name = "dsv-bin", mount_path = local.dsv_bin_dir, empty_dir = true, secret = null, read_only = false },
        { name = "agent-config", mount_path = local.agent_cfg_dir, empty_dir = false, read_only = true, secret = {
          "datadog.yaml"  = base64encode(local.agent_datadog_yaml)
          "app-logs.yaml" = base64encode(local.agent_logs_conf)
          "dsv.json"      = base64encode(local.agent_dsv_json)
        } },
      ],
      local.collector == "agent_sidecar" ? [{ name = "app-logs", mount_path = local.log_dir, empty_dir = true, secret = null, read_only = false }] : [],
    )
    liveness_exec = ["agent", "health"]
  }]
  # Fluent Bit fallback + dsv-fetch refresher; Fluent Bit fails fast while the include file is missing.
  aci_fluent_bit = [for _ in(local.uses_sidecar && var.architecture == "aci" ? [1] : []) : {
    name                         = "fluent-bit"
    image                        = var.telemetry.fluentbit.sidecar_image
    cpu                          = var.sidecar_resources.cpu
    memory                       = 0.5
    commands                     = ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/etc/eh/fluent-bit.yaml"]
    environment_variables        = local.sidecar_env
    secure_environment_variables = {}
    volumes = concat(
      [
        { name = "app-logs", mount_path = local.log_dir, empty_dir = true, secret = null, read_only = false },
        { name = "flb-config", mount_path = "/fluent-bit/etc/eh", empty_dir = false, read_only = true, secret = local.sidecar_files_ready ? {
          "fluent-bit.yaml" = base64encode(local.sidecar_config)
          "parsers.yaml"    = base64encode(var.telemetry.fluentbit.sidecar_parsers)
        } : null },
        { name = "flb-lua", mount_path = "/fluent-bit/etc/eh/lua", empty_dir = false, read_only = true, secret = local.sidecar_files_ready ? {
          "enterprise_hello.lua" = base64encode(var.telemetry.fluentbit.sidecar_lua)
        } : null },
      ],
      local.needs_fetch ? [{ name = "dsv-secrets", mount_path = local.secrets_dir, empty_dir = true, secret = null, read_only = false }] : [],
    )
    liveness_exec = null
  }]
  aci_refresher = [for _ in(local.needs_fetch && var.architecture == "aci" ? [1] : []) : {
    name                         = "dsv-fetch"
    image                        = var.telemetry.secrets.fetch_image
    cpu                          = var.fetch_resources.aci_cpu
    memory                       = var.fetch_resources.aci_mem
    commands                     = concat([local.fetch_bin_src], local.refresh_args)
    environment_variables        = local.fetch_env
    secure_environment_variables = {}
    volumes                      = [{ name = "dsv-secrets", mount_path = local.secrets_dir, empty_dir = true, secret = null, read_only = false }]
    liveness_exec                = null
  }]
  aci_sidecar = !local.uses_agent_sidecar && !(local.uses_sidecar && var.architecture == "aci") ? null : {
    log_collector = local.log_collector
    init_containers = [for _ in(local.uses_agent_sidecar ? [1] : []) : {
      name                  = "dsv-fetch-install"
      image                 = var.telemetry.secrets.fetch_image
      commands              = [local.fetch_bin_src, "install", "--dest", local.dsv_bin]
      environment_variables = {}
      volumes               = [{ name = "dsv-bin", mount_path = local.dsv_bin_dir, empty_dir = true, secret = null, read_only = false }]
    }]
    containers        = concat(local.aci_agent, local.aci_fluent_bit, local.aci_refresher)
    app_volume_mounts = local.aci_file_logs ? [{ name = "app-logs", mount_path = local.log_dir }] : []
  }

  # Kubernetes Deployment strategic-merge patch (node Agent / Fluent Bit DaemonSet collect stdout).
  k8s_labels = merge(
    module.tags.k8s_labels,
    { "logs.datadoghq.com/source" = local.dd_source },
    local.apm.method == "ssi_kubernetes" ? { "admission.datadoghq.com/enabled" = "true" } : {},
  )
  k8s_annotations = merge(
    module.tags.k8s_annotations,
    local.log_collector == "datadog-agent" ? { "ad.datadoghq.com/${local.container}.logs" = jsonencode([{ source = local.dd_source, service = local.u.service }]) } : {},
  )

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

# Plan-time warnings (pure module: no resources to attach preconditions to).
check "datadog_sidecar_inputs" {
  assert {
    condition     = !(local.uses_agent_sidecar || local.uses_serverless_init) || (local.uses_agent_sidecar ? local.agent_image != null : local.si_image != null)
    error_message = "Datadog sidecar without an image: set agent.image + agent.version (ACI) / agent.serverless_init.image + version (Container Apps) in the fleet policy, or the agent_sidecar / serverless_init image input."
  }
  assert {
    condition     = !local.op_mode || !contains(["agent_sidecar", "serverless_init"], local.collector) || local.op_logs_url != null
    error_message = "log_pipeline = observability_pipelines but the transport contract has no aggregator.agent_logs_url: the ${local.collector} sidecar does not collect application logs (no direct-to-intake bypass of the Worker)."
  }
}
