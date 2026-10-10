# Fleet policy resolution (pure function, no providers): defaults -> architectures.<arch> -> environments.<env> ->
# per-workload overrides, then the Datadog support matrix (verified against docs.datadoghq.com on 2026-10-09; see
# docs/guides/datadog-fleet-collection.md in the source repository) decides the EFFECTIVE collection method.
locals {
  # (tuple + index: a conditional would force both policies to the same object type)
  policy = [for p in [var.policy, yamldecode(file("${path.module}/../../config/fleet-policy.yaml"))] : p if p != null][0]
  arch_o = try(local.policy.architectures[var.architecture], {})
  env_o  = try(local.policy.environments[var.env], {})
  o      = [for x in [var.overrides, {}] : x if x != null][0]

  section = { for s in ["logs", "apm", "profiling", "agent", "rum", "op_worker"] : s => merge(
    try(local.policy[s], {}), try(local.arch_o[s], {}), try(local.env_o[s], {}), try(local.o[s], {}),
  ) }
  log_pipeline = try(local.o.log_pipeline, try(local.env_o.log_pipeline, try(local.arch_o.log_pipeline, try(local.policy.log_pipeline, "observability_pipelines"))))

  apm       = local.section.apm
  prof      = local.section.profiling
  arch      = var.architecture == null ? "" : var.architecture
  runtime   = var.runtime == null ? "other" : var.runtime
  requested = var.runtime == "browser" || var.runtime == null || var.runtime == "other" ? "none" : try(local.apm.mode, "datadog")
  linux     = var.os_type == "linux"

  managed            = contains(["aca", "aci", "appservice", "functions"], local.arch)
  runtime_path       = try(local.apm.managed_runtime_path, "agent_gateway")
  serverless_init_ok = local.arch == "aca" && local.runtime_path == "serverless_init"
  agent_sidecar_ok   = local.arch == "aci" && local.runtime_path == "agent_sidecar"

  # Datadog-mode method per hosting type; null = Datadog tracer not configurable there (falls back to otel).
  datadog_method = (
    local.arch == "aks" ? "ssi_kubernetes" :
    contains(["vm", "vmss"], local.arch) ? (local.linux ? "ssi_host" : null) :
    local.managed ? (local.serverless_init_ok ? "serverless_init" : local.agent_sidecar_ok ? "agent_sidecar" : "agent_gateway") :
    null
  )
  fallback_reason = local.requested != "datadog" || local.datadog_method != null ? null : (
    contains(["vm", "vmss"], local.arch) ? "Windows hosts: Single Step Instrumentation is Linux / IIS only; the package keeps OpenTelemetry for Windows services" :
    local.arch == "logicapp" ? "Logic Apps: no application tracer" : "no Datadog tracer path for architecture '${local.arch}'"
  )
  effective_mode = local.requested == "datadog" && local.datadog_method == null ? (local.arch == "logicapp" ? "none" : "otel") : local.requested
  method = (
    local.effective_mode == "datadog" ? local.datadog_method :
    local.effective_mode == "otel" ? (contains(["aks", "vm", "vmss"], local.arch) ? "otlp_agent" : "otlp_gateway") :
    "none"
  )

  # ------------------------------------------------------------------ Continuous Profiler support matrix
  # .NET: Linux + Windows x64, App Service Web Apps yes, Function Apps NOT supported. Python: POSIX (CPU profile
  # POSIX only); Azure Functions = preview only. Logic Apps / browser: none. OTel mode: Datadog library required.
  profiler_supported = (
    local.runtime == "dotnet" ? !contains(["functions", "logicapp"], local.arch) :
    local.runtime == "python" ? local.linux && !contains(["functions", "logicapp"], local.arch) :
    contains(["node", "java"], local.runtime) ? !contains(["logicapp"], local.arch) :
    false
  )
  profiling_requested = try(local.prof.enabled, true)
  otel_preview        = local.effective_mode == "otel" && try(local.prof.otel_mode, "unavailable") == "python_preview" && local.runtime == "python" && local.profiler_supported
  profiling_enabled   = local.profiling_requested && local.profiler_supported && (local.effective_mode == "datadog" || local.otel_preview)
  profiling_reason = local.profiling_enabled ? null : (
    !local.profiler_supported ? "Datadog Continuous Profiler does not support ${local.runtime} on ${local.arch == "" ? "this platform" : local.arch}${local.linux ? "" : " (Windows)"}" :
    !local.profiling_requested ? "disabled by the fleet policy" :
    local.effective_mode == "otel" ? "apm.mode = otel: Datadog profiling needs the Datadog library (set profiling.otel_mode = python_preview for Python)" :
    "apm.mode = none"
  )

  dn = try(local.prof.dotnet, {})
  py = try(local.prof.python, {})
  # SSI: "auto" profiles only eligible processes (Datadog recommendation for Single Step Instrumentation)
  profiling_switch = contains(["ssi_kubernetes", "ssi_host"], coalesce(local.method, "none")) ? "auto" : "true"
  profiling_env = !local.profiling_enabled ? {} : merge(
    {
      DD_PROFILING_ENABLED                     = local.profiling_switch
      DD_PROFILING_ENDPOINT_COLLECTION_ENABLED = "true"
    },
    local.runtime == "dotnet" ? {
      DD_PROFILING_CPU_ENABLED          = tostring(try(local.dn.cpu, true))
      DD_PROFILING_WALLTIME_ENABLED     = tostring(try(local.dn.walltime, true))
      DD_PROFILING_EXCEPTION_ENABLED    = tostring(try(local.dn.exceptions, true))
      DD_PROFILING_GC_ENABLED           = tostring(try(local.dn.gc, true))
      DD_PROFILING_LOCK_ENABLED         = tostring(try(local.dn.lock, false))
      DD_PROFILING_ALLOCATION_ENABLED   = tostring(try(local.dn.allocation, false))
      DD_PROFILING_HEAP_ENABLED         = tostring(try(local.dn.heap, false))
      DD_PROFILING_CODEHOTSPOTS_ENABLED = "true"
    } : {},
    local.runtime == "python" ? {
      DD_PROFILING_STACK_ENABLED    = tostring(try(local.py.stack, true))
      DD_PROFILING_LOCK_ENABLED     = tostring(try(local.py.lock, true))
      DD_PROFILING_MEMORY_ENABLED   = tostring(try(local.py.memory, true))
      DD_PROFILING_HEAP_ENABLED     = tostring(try(local.py.heap, true))
      DD_PROFILING_TIMELINE_ENABLED = tostring(try(local.py.timeline, true))
    } : {},
    local.otel_preview ? { DD_PROFILING_PREVIEW_OTEL_CONTEXT_ENABLED = "true" } : {},
  )

  # ------------------------------------------------------------------ APM library settings (datadog mode)
  dbm_mode = try(local.apm.dbm_propagation, "full")
  # .NET: SqlClient / Npgsql / MySql full or service; Python: psycopg / asyncpg / mysql drivers (no SQL Server).
  dbm_env = local.effective_mode == "datadog" && local.dbm_mode != "disabled" && contains(["dotnet", "python", "java", "node"], local.runtime) ? {
    DD_DBM_PROPAGATION_MODE = local.dbm_mode
  } : {}
  # Data Streams Monitoring: Azure Service Bus is supported for .NET (Azure.Messaging.ServiceBus, tracer >= 2.53.0):
  # activity source + OTel API bridge required. Python Service Bus is not a DSM technology.
  dsm_env = local.effective_mode == "datadog" && try(local.apm.data_streams, true) && local.runtime == "dotnet" ? {
    DD_DATA_STREAMS_ENABLED                   = "true"
    AZURE_EXPERIMENTAL_ENABLE_ACTIVITY_SOURCE = "true"
  } : {}
  sample_rate = try(local.apm.sample_rate, null)
  # Datadog-mode library contract agreed with the application libraries (applications/shared/python/hello_common,
  # applications/dotnet): one tracer per process, the OTel API bridged into the Datadog tracer (manual
  # Activity / OTel-API spans), custom hello.* metrics over DogStatsD. NEVER OTEL_EXPORTER_OTLP_* / OTEL_SDK_DISABLED
  # here (the apps read TELEMETRY_SDK) and no OTEL_RESOURCE_ATTRIBUTES (Datadog maps it to DD_TAGS -> duplicates).
  apm_env = local.effective_mode != "datadog" ? {} : merge(
    {
      TELEMETRY_SDK                                     = "datadog"
      DD_TRACE_ENABLED                                  = "true"
      DD_TRACE_OTEL_ENABLED                             = "true"
      DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED = "true"
      DD_LOGS_INJECTION                                 = tostring(try(local.apm.logs_injection, true))
      DD_METRICS_OTEL_ENABLED                           = "false"
      # runtime metrics travel over DogStatsD (UDP/UDS): only where an Agent runs next to the process (node Agent,
      # host Agent, ACI Agent sidecar, serverless-init); the APM gateway's TCP ingress cannot carry them
      DD_RUNTIME_METRICS_ENABLED = tostring(local.dogstatsd_local)
    },
    local.sample_rate == null ? {} : { DD_TRACE_SAMPLE_RATE = tostring(local.sample_rate) },
    local.dbm_env, local.dsm_env,
  )
  # DogStatsD target of the Datadog libraries (hello.* custom metrics, runtime metrics). AKS: DD_AGENT_HOST =
  # status.hostIP (modules/instrumentation k8s_patch) + port; hosts / ACI Agent sidecar / serverless-init sidecar:
  # localhost (containers of an ACI group / Container Apps replica share one network namespace).
  dogstatsd_local = contains(["ssi_kubernetes", "ssi_host", "serverless_init", "agent_sidecar"], coalesce(local.method, "none"))
  dogstatsd_env = local.effective_mode != "datadog" ? {} : (
    local.method == "ssi_kubernetes" ? { DD_DOGSTATSD_PORT = "8125" } :
    contains(["ssi_host", "serverless_init", "agent_sidecar"], coalesce(local.method, "none")) ? { DD_DOGSTATSD_URL = "udp://localhost:8125" } : {}
  )

  # ------------------------------------------------------------------ application-log collector (4.0.0)
  # One Datadog collection path per platform. Defaults per architecture (config/fleet-policy.yaml architectures.*,
  # repeated here for custom policies that omit them); Fluent Bit only with log_pipeline = fluent_bit_direct (and on
  # Batch nodes, where no Agent runs).
  default_collector = lookup({
    aks        = "agent", vm = "agent", vmss = "agent", aci = "agent_sidecar", aca = "serverless_init",
    appservice = "azure", functions = "azure", logicapp = "azure", batch = "fluent_bit",
  }, local.arch, "none")
  allowed_collectors = {
    aks        = ["agent", "fluent_bit"], vm = ["agent", "fluent_bit"], vmss = ["agent", "fluent_bit"],
    aci        = ["agent_sidecar"], aca = ["serverless_init", "azure"],
    appservice = ["azure"], functions = ["azure"], logicapp = ["azure"], batch = ["fluent_bit"],
  }
  node_arch   = contains(["aks", "vm", "vmss"], local.arch)
  legacy_node = try(local.section.logs.node_collector, null)
  # 3.x key: logs.node_collector = fluent_bit on a node architecture still selects Fluent Bit there
  requested_collector = local.node_arch && local.legacy_node == "fluent_bit" ? "fluent_bit" : coalesce(try(local.section.logs.collector, null), local.default_collector)
  collector_valid     = contains(lookup(local.allowed_collectors, local.arch, ["none"]), local.requested_collector)
  chosen_collector    = local.collector_valid ? local.requested_collector : local.default_collector
  fb_direct           = local.log_pipeline == "fluent_bit_direct"
  log_collector = !local.fb_direct || contains(["azure", "none"], local.chosen_collector) ? local.chosen_collector : (
    contains(["aca", "aci"], local.arch) ? "fluent_bit_sidecar" : "fluent_bit"
  )
  log_collector_reason = !local.collector_valid ? "logs.collector '${local.requested_collector}' is not a collection path for '${local.arch}' (allowed: ${join(", ", lookup(local.allowed_collectors, local.arch, ["none"]))}); using ${local.default_collector}" : (
    local.log_collector != local.chosen_collector ? "log_pipeline = fluent_bit_direct: Fluent Bit replaces ${local.chosen_collector}" : null
  )

  # ------------------------------------------------------------------ Datadog sidecar images (single pins)
  agent_s     = local.section.agent
  agent_image = try("${local.agent_s.image}:${local.agent_s.version}", null)
  si          = try(local.agent_s.serverless_init, {})
}
