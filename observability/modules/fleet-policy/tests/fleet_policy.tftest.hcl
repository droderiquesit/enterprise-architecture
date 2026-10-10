# Plan-only tests of the fleet policy resolution (no providers).
run "aks_dotnet_ssi_with_profiler_dsm_dbm" {
  command = plan
  variables {
    architecture = "aks"
    runtime      = "dotnet"
    env          = "dev"
  }
  assert {
    condition     = output.apm.mode == "datadog" && output.apm.method == "ssi_kubernetes" && output.log_pipeline == "observability_pipelines" && output.node_collector == "agent"
    error_message = "AKS default: Datadog SSI + OP + Agent log collection"
  }
  assert {
    condition = alltrue([
      output.profiling.enabled,
      output.profiling.env["DD_PROFILING_ENABLED"] == "auto",
      output.profiling.env["DD_PROFILING_EXCEPTION_ENABLED"] == "true",
      output.profiling.env["DD_PROFILING_HEAP_ENABLED"] == "false",
      output.profiling.env["DD_PROFILING_CODEHOTSPOTS_ENABLED"] == "true",
    ])
    error_message = ".NET profiler: auto under SSI, exceptions on, preview heap off, code hotspots on"
  }
  assert {
    condition     = output.apm_env["TELEMETRY_SDK"] == "datadog" && output.apm_env["OTEL_SDK_DISABLED"] == "true" && output.apm_env["DD_DATA_STREAMS_ENABLED"] == "true" && output.apm_env["AZURE_EXPERIMENTAL_ENABLE_ACTIVITY_SOURCE"] == "true" && output.apm_env["DD_DBM_PROPAGATION_MODE"] == "full"
    error_message = "datadog mode: SDK switch, DSM for Service Bus (.NET), DBM propagation"
  }
  assert {
    condition     = !contains(keys(output.apm_env), "DD_TRACE_SAMPLE_RATE")
    error_message = "sampling left to the Agent by default"
  }
  assert {
    condition     = output.apm_env["DD_RUNTIME_METRICS_ENABLED"] == "true"
    error_message = "Runtime metrics to the node Agent"
  }
}

run "aca_python_agent_gateway" {
  command = plan
  variables {
    architecture = "aca"
    runtime      = "python"
  }
  assert {
    condition     = output.apm.method == "agent_gateway" && output.profiling.env["DD_PROFILING_ENABLED"] == "true" && output.profiling.env["DD_PROFILING_MEMORY_ENABLED"] == "true"
    error_message = "managed runtime: tracer -> APM gateway; Python profiler on"
  }
  assert {
    condition     = !contains(keys(output.apm_env), "DD_DATA_STREAMS_ENABLED")
    error_message = "no DSM for Python Service Bus"
  }
  assert {
    condition     = output.apm_env["DD_RUNTIME_METRICS_ENABLED"] == "false"
    error_message = "Runtime metrics need DogStatsD next to the process: off behind the APM gateway"
  }
}

run "functions_profiler_unsupported" {
  command = plan
  variables {
    architecture = "functions"
    runtime      = "dotnet"
  }
  assert {
    condition     = output.apm.method == "agent_gateway" && !output.profiling.enabled && length(output.profiling.env) == 0 && output.profiling.reason != null
    error_message = ".NET Function Apps: tracing yes, profiler not supported (reason reported)"
  }
}

run "windows_vm_falls_back_to_otel" {
  command = plan
  variables {
    architecture = "vm"
    runtime      = "dotnet"
    os_type      = "windows"
  }
  assert {
    condition     = output.apm.requested_mode == "datadog" && output.apm.mode == "otel" && output.apm.method == "otlp_agent" && output.apm.fallback_reason != null && !output.profiling.enabled
    error_message = "Windows host: no SSI -> OpenTelemetry fallback, profiler unavailable in otel mode"
  }
}

run "otel_mode_python_profiling_preview_opt_in" {
  command = plan
  variables {
    architecture = "aks"
    runtime      = "python"
    overrides = {
      apm       = { mode = "otel" }
      profiling = { otel_mode = "python_preview" }
    }
  }
  assert {
    condition     = output.apm.method == "otlp_agent" && output.profiling.enabled && output.profiling.preview && output.profiling.env["DD_PROFILING_PREVIEW_OTEL_CONTEXT_ENABLED"] == "true" && length(output.apm_env) == 0
    error_message = "otel mode: no Datadog tracer env; Python profiler only as documented preview"
  }
}

run "environment_and_architecture_overrides" {
  command = plan
  variables {
    architecture = "logicapp"
    runtime      = "dotnet"
    env          = "prod"
    policy = {
      apiVersion   = "observability/fleet-policy/v1"
      kind         = "FleetPolicy"
      log_pipeline = "fluent_bit_direct"
      apm          = { mode = "datadog", sample_rate = 1 }
      architectures = {
        logicapp = { apm = { mode = "none" } }
      }
      environments = {
        prod = { apm = { sample_rate = 0.2 } }
      }
    }
  }
  assert {
    condition     = output.apm.mode == "none" && output.apm.sample_rate == 0.2 && output.log_pipeline == "fluent_bit_direct" && output.node_collector == "fluent_bit"
    error_message = "precedence defaults -> architecture -> environment"
  }
}

run "aca_serverless_init_opt_in" {
  command = plan
  variables {
    architecture = "aca"
    runtime      = "dotnet"
    overrides    = { apm = { managed_runtime_path = "serverless_init" } }
  }
  assert {
    condition     = output.apm.method == "serverless_init"
    error_message = "serverless-init only on explicit opt-in"
  }
}
