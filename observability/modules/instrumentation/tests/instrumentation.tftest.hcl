# Plan-only tests of the pure instrumentation hook (no providers involved).
# The file-level default is apm.mode = otel (the 2.x OTLP path); the datadog-mode runs override it.
variables {
  apm = { mode = "otel" }
  service = {
    service     = "hello-orders-api"
    env         = "dev"
    version     = "1.4.2"
    team        = "orders"
    domain      = "commerce"
    tier        = "backend"
    application = "enterprise-hello"
    owner       = "orders-team@example.com"
    region      = "swedencentral"
  }
  runtime      = "dotnet"
  architecture = "aks"
  telemetry = {
    datadog_site = "datadoghq.eu"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    secrets = {
      tenant      = "contoso"
      base_url    = "https://contoso.secretsvaultcloud.com/v1"
      fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
    otlp = {
      grpc_endpoint = "http://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io:4317"
      http_endpoint = "https://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io"
      headers_ref   = "dsv://eh/dev/otlp-headers#value"
    }
    fluentbit = {
      forward_host    = "ca-flb.internal.example.swedencentral.azurecontainerapps.io"
      forward_port    = 24224
      sidecar_config  = "service: {}\n"
      sidecar_parsers = "parsers: []\n"
      sidecar_lua     = "-- lua\n"
    }
    aggregator = { kind = "observability_pipelines", agent_logs_url = "http://opw.internal.example:8282" }
    env = {
      common = { OTEL_BSP_MAX_EXPORT_BATCH_SIZE = "512", OTEL_EXPORTER_OTLP_PROTOCOL = "overridden-by-module" }
      dotnet = { DOTNET_EXTRA = "1" }
    }
  }
}

run "aks_dotnet_uses_node_agent_and_daemonset" {
  command = plan
  assert {
    condition     = output.log_route == "daemonset" && output.otlp_target == "agent"
    error_message = "AKS must use the Fluent Bit DaemonSet and the node Agent."
  }
  assert {
    condition     = output.env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://$(DD_AGENT_HOST):4317" && output.env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "grpc"
    error_message = "AKS OTLP must target the node-local agent over gRPC via the downward API."
  }
  assert {
    condition     = !contains(keys(output.env), "LOG_FILE_PATH") && output.env["OTEL_LOGS_EXPORTER"] == "none"
    error_message = "AKS apps log to stdout only (no file, no OTLP logs)."
  }
  assert {
    condition     = output.env["OTEL_BSP_MAX_EXPORT_BATCH_SIZE"] == "512" && output.env["DOTNET_EXTRA"] == "1"
    error_message = "Contract env defaults (common + runtime) must be merged."
  }
  assert {
    condition     = strcontains(output.k8s_patch, "status.hostIP") && strcontains(output.k8s_patch, "tags.datadoghq.com/service")
    error_message = "k8s patch must carry DD_AGENT_HOST from status.hostIP and unified service labels."
  }
  assert {
    condition     = output.k8s_patch_object.spec.template.spec.containers[0].env[0].name == "DD_AGENT_HOST"
    error_message = "DD_AGENT_HOST must be declared before env vars that reference it."
  }
  assert {
    condition     = strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "deployment.environment.name=dev") && strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "cloud.platform=azure_aks")
    error_message = "Resource attributes must map env and platform."
  }
  assert {
    condition     = length(output.container_app_patch.sidecars) == 0 && output.aci_sidecar == null && length(output.secret_env) == 0
    error_message = "No sidecar and no gateway secrets on AKS."
  }
}

run "aca_python_fluent_bit_direct_fallback" {
  command = plan
  variables {
    runtime            = "python"
    architecture       = "aca"
    identity_client_id = "33333333-3333-3333-3333-333333333333"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { tenant = "contoso", base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp = {
        grpc_endpoint = "http://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io:4317"
        http_endpoint = "https://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io"
        headers_ref   = "dsv://eh/dev/otlp-headers#value"
      }
      fluentbit = { forward_host = "ca-flb", forward_port = 24224, sidecar_config = "service: {}\n", sidecar_parsers = "parsers: []\n", sidecar_lua = "-- lua\n" }
      # lab seam: the transport contract's fleet switch selects the fallback
      env = { fleet = { EH_LOG_PIPELINE = "fluent_bit_direct" } }
    }
  }
  assert {
    condition     = output.log_collector == "fluent-bit-sidecar" && output.log_collector_reason != null && length([for c in output.container_app_patch.sidecars : c if c.name == "datadog"]) == 0
    error_message = "fluent_bit_direct: Fluent Bit sidecar replaces serverless-init as the log collector (otel mode: no serverless-init)"
  }
  assert {
    condition     = output.log_route == "sidecar" && output.env["LOG_FILE_PATH"] == "/var/log/app/app.log"
    error_message = "ACA must write the shared log file for the sidecar."
  }
  assert {
    condition     = output.env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "https://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io" && output.env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/protobuf"
    error_message = "ACA must use the gateway HTTP endpoint by default."
  }
  assert {
    condition     = output.secret_env["OTEL_EXPORTER_OTLP_HEADERS"] == "dsv://eh/dev/otlp-headers#value" && output.env["OTEL_EXPORTER_OTLP_HEADERS"] == "dsv://eh/dev/otlp-headers#value"
    error_message = "OTLP auth header is a DSV reference in the app env (resolved by the app)."
  }
  assert {
    condition     = output.env["DSV_TENANT"] == "contoso" && output.env["DSV_TLD"] == "com" && output.env["DSV_BASE_URL"] == "https://contoso.secretsvaultcloud.com/v1" && output.env["DSV_AUTH"] == "azure" && output.env["AZURE_CLIENT_ID"] == "33333333-3333-3333-3333-333333333333"
    error_message = "DSV runtime env defaults for the app."
  }
  assert {
    condition = (length(output.container_app_patch.init_containers) == 1
      && output.container_app_patch.init_containers[0].name == "dsv-fetch"
      && output.container_app_patch.init_containers[0].needs_identity
      && join(" ", output.container_app_patch.refresher_containers[0].args) == "init --out /dsv-secrets --format env-yaml --env-yaml-name fluentbit-env.yaml --map DD_API_KEY=dsv://eh/dev/datadog-api-key#value --refresh-seconds 3600 --retry-seconds 30"
      && startswith(output.container_app_patch.init_containers[0].image, "ehacr.azurecr.io/dsv-fetch@sha256:")
      && join(" ", output.container_app_patch.init_containers[0].args) == "init --out /dsv-secrets --format env-yaml --env-yaml-name fluentbit-env.yaml --map DD_API_KEY=dsv://eh/dev/datadog-api-key#value"
    && anytrue([for e in output.container_app_patch.init_containers[0].env : e.name == "AZURE_CLIENT_ID" && e.value == "33333333-3333-3333-3333-333333333333"]))
    error_message = "ACA: a dsv-fetch init container writes the Fluent Bit env-yaml file with the app identity."
  }
  assert {
    condition     = anytrue([for v in output.container_app_patch.volumes : v.name == "dsv-secrets" && v.storage_type == "EmptyDir"]) && anytrue([for m in output.container_app_patch.sidecars[0].volume_mounts : m.name == "dsv-secrets" && m.path == "/dsv-secrets"])
    error_message = "The env file lives on an EmptyDir shared by init container and sidecar."
  }
  assert {
    condition     = length(output.container_app_patch.sidecars) == 1 && output.container_app_patch.sidecars[0].image == "fluent/fluent-bit:5.1.3"
    error_message = "One pinned Fluent Bit sidecar expected."
  }
  assert {
    condition     = !strcontains(jsonencode(output.container_app_patch), "key_vault") && !anytrue([for e in output.container_app_patch.sidecars[0].env : e.name == "DD_API_KEY"]) && length(output.container_app_patch.secrets) == 3
    error_message = "No Key Vault references and no API key env on the sidecar; ACA secrets carry only the 3 config files."
  }
  assert {
    condition     = anytrue([for e in output.container_app_patch.sidecars[0].env : e.name == "FLB_DD_HOST" && e.value == "http-intake.logs.datadoghq.eu"])
    error_message = "Logs intake host must follow the Datadog site."
  }
  assert {
    condition     = anytrue([for e in output.container_app_patch.sidecars[0].env : e.name == "FLB_DD_TLS" && e.value == "on"])
    error_message = "TLS must be on for the Datadog output."
  }
  assert {
    condition     = output.env["OTEL_PYTHON_LOG_CORRELATION"] == "true"
    error_message = "Python runtime env expected."
  }
}

run "aca_sidecar_forward_mode" {
  command = plan
  variables {
    architecture = "aca"
    telemetry = {
      datadog_site = "datadoghq.com"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp = {
        grpc_endpoint = ""
        http_endpoint = "https://gw"
      }
      fluentbit = {
        forward_host           = "ca-flb"
        forward_port           = 24224
        sidecar_mode           = "forward"
        sidecar_forward_config = "service: {}\n"
        sidecar_parsers        = "parsers: []\n"
        sidecar_lua            = "-- lua\n"
        forward_shared_key_ref = "dsv://eh/dev/fluentbit-shared-key#value"
      }
      env = { fleet = { EH_LOG_PIPELINE = "fluent_bit_direct" } }
    }
  }
  assert {
    condition     = anytrue([for e in output.container_app_patch.sidecars[0].env : e.name == "FLB_FORWARD_HOST" && e.value == "ca-flb"])
    error_message = "Forward mode must target the aggregator."
  }
  assert {
    condition     = jsonencode(output.sidecar_secret_refs) == jsonencode({ FLB_FORWARD_SHARED_KEY = "dsv://eh/dev/fluentbit-shared-key#value" }) && strcontains(join(" ", output.container_app_patch.init_containers[0].args), "--map FLB_FORWARD_SHARED_KEY=dsv://eh/dev/fluentbit-shared-key#value")
    error_message = "Forward mode fetches the shared key, not the Datadog API key."
  }
}

run "appservice_eventhub_route_app_settings" {
  command = plan
  variables {
    architecture = "appservice"
  }
  assert {
    condition     = output.log_route == "eventhub" && !contains(keys(output.app_settings), "LOG_FILE_PATH")
    error_message = "App Service logs go console -> diagnostic settings -> Event Hubs; no file sink."
  }
  assert {
    condition     = output.app_settings["OTEL_EXPORTER_OTLP_HEADERS"] == "dsv://eh/dev/otlp-headers#value" && output.app_settings["DSV_AUTH"] == "azure" && !strcontains(jsonencode(output.app_settings), "@Microsoft.KeyVault(")
    error_message = "App settings carry dsv:// values (resolved by the app) and the DSV env; no Key Vault references."
  }
}

run "functions_enable_host_otel" {
  command = plan
  variables {
    architecture = "functions"
  }
  assert {
    condition     = output.app_settings["AzureFunctionsJobHost__telemetryMode"] == "OpenTelemetry"
    error_message = "Functions host OpenTelemetry mode expected."
  }
}

run "aci_agent_sidecar_otel_mode_collects_logs" {
  command = plan
  variables {
    architecture       = "aci"
    runtime            = "python"
    identity_client_id = "44444444-4444-4444-4444-444444444444"
  }
  assert {
    condition     = output.log_collector == "datadog-agent-sidecar" && output.log_route == "sidecar" && output.env["LOG_FILE_PATH"] == "/var/log/app/app.log" && output.apm.method == "otlp_gateway"
    error_message = "ACI default: the Agent sidecar tails the app log file (apm.mode = otel here: traces still OTLP -> gateway)"
  }
  assert {
    condition     = jsonencode([for c in output.aci_sidecar.containers : c.name]) == jsonencode(["datadog-agent"]) && jsonencode([for c in output.aci_sidecar.init_containers : c.name]) == jsonencode(["dsv-fetch-install"])
    error_message = "ACI: one Agent sidecar + the dsv-fetch binary installer init container; no Fluent Bit, no refresher"
  }
  assert {
    condition     = yamldecode(output.aci_agent_files["datadog.yaml"]).logs_enabled && !yamldecode(output.aci_agent_files["datadog.yaml"]).apm_config.enabled
    error_message = "otel mode: the Agent sidecar collects logs only (its trace-agent is off)"
  }
  assert {
    condition     = output.aci_sidecar.containers[0].environment_variables["DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED"] == "true" && output.aci_sidecar.containers[0].environment_variables["DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL"] == "http://opw.internal.example:8282"
    error_message = "observability_pipelines mode: the Agent ships logs to the OP Worker Datadog Agent source"
  }
  assert {
    condition     = jsondecode(output.aci_agent_files["dsv.json"]).AZURE_CLIENT_ID == "44444444-4444-4444-4444-444444444444" && jsondecode(output.aci_agent_files["dsv.json"]).DSV_AUTH == "azure"
    error_message = "the secret backend authenticates to DSV with the container group identity"
  }
}

run "datadog_mode_aci_agent_sidecar" {
  command = plan
  variables {
    apm          = null
    architecture = "aci"
    runtime      = "dotnet"
  }
  assert {
    condition     = output.apm.method == "agent_sidecar" && output.env["DD_DOGSTATSD_URL"] == "udp://localhost:8125" && output.env["DD_RUNTIME_METRICS_ENABLED"] == "true" && !contains(keys(output.env), "DD_TRACE_AGENT_URL")
    error_message = "ACI datadog mode: tracer -> localhost:8126 (default), DogStatsD + runtime metrics to the sidecar (gap closed)"
  }
  assert {
    condition     = output.env["CORECLR_ENABLE_PROFILING"] == "1" && output.env["DD_PROFILING_ENABLED"] == "true"
    error_message = ".NET tracer + profiler from the image on the agent_sidecar path"
  }
  assert {
    condition = alltrue([
      output.aci_sidecar.containers[0].image == "gcr.io/datadoghq/agent:7.84.2",
      output.aci_sidecar.containers[0].cpu == 0.25,
      output.aci_sidecar.containers[0].memory == 0.5,
      length(output.aci_sidecar.containers[0].secure_environment_variables) == 0,
      output.aci_sidecar.containers[0].environment_variables["DD_API_KEY"] == "ENC[dsv://eh/dev/datadog-api-key#value]",
      jsonencode(output.aci_sidecar.containers[0].liveness_exec) == jsonencode(["agent", "health"]),
    ])
    error_message = "pinned Agent image (fleet policy), 0.25 vCPU / 0.5 GB, only an ENC[] reference as DD_API_KEY"
  }
  assert {
    condition = alltrue([
      yamldecode(output.aci_agent_files["datadog.yaml"]).api_key == "ENC[dsv://eh/dev/datadog-api-key#value]",
      yamldecode(output.aci_agent_files["datadog.yaml"]).secret_backend_command == "/opt/dsv-fetch/dsv-fetch",
      jsonencode(yamldecode(output.aci_agent_files["datadog.yaml"]).secret_backend_arguments) == jsonencode(["agent-backend", "--config", "/eh/agent/dsv.json"]),
      yamldecode(output.aci_agent_files["datadog.yaml"]).apm_config.enabled,
      !yamldecode(output.aci_agent_files["datadog.yaml"]).apm_config.apm_non_local_traffic,
      !yamldecode(output.aci_agent_files["datadog.yaml"]).dogstatsd_non_local_traffic,
      yamldecode(output.aci_agent_files["datadog.yaml"]).remote_configuration.enabled,
      contains(yamldecode(output.aci_agent_files["datadog.yaml"]).apm_config.ignore_resources, "GET /healthz"),
      yamldecode(output.aci_agent_files["datadog.yaml"]).hostname == "hello-orders-api-dev",
    ])
    error_message = "datadog.yaml: key via the dsv-fetch secret backend, APM + DogStatsD on localhost only, Remote Configuration on"
  }
  assert {
    condition     = yamldecode(output.aci_agent_files["app-logs.yaml"]).logs[0].path == "/var/log/app/app.log" && yamldecode(output.aci_agent_files["app-logs.yaml"]).logs[0].source == "csharp" && yamldecode(output.aci_agent_files["app-logs.yaml"]).logs[0].service == "hello-orders-api" && contains(yamldecode(output.aci_agent_files["app-logs.yaml"]).logs[0].tags, "env:dev") && contains(yamldecode(output.aci_agent_files["app-logs.yaml"]).logs[0].tags, "team:orders")
    error_message = "the Agent tails LOG_FILE_PATH with source/service"
  }
  assert {
    condition     = jsonencode(output.aci_sidecar.init_containers[0].commands) == jsonencode(["/opt/dsv-fetch/dsv-fetch", "install", "--dest", "/eh/dsv-bin/dsv-fetch"]) && startswith(output.aci_agent_files.start, "/eh/dsv-bin/dsv-fetch install --dest /opt/dsv-fetch/dsv-fetch && ") && endswith(output.aci_agent_files.start, "exec /bin/entrypoint.sh") && !strcontains(jsonencode(output.aci_sidecar), "python")
    error_message = "init container installs the binary (no identity needed); the Agent re-installs it root-owned 0500 and execs the entrypoint; no Python anywhere"
  }
  assert {
    condition     = jsonencode(output.aci_sidecar.app_volume_mounts) == jsonencode([{ mount_path = "/var/log/app", name = "app-logs" }]) && anytrue([for v in output.aci_sidecar.containers[0].volumes : v.name == "app-logs" && v.empty_dir])
    error_message = "app and Agent share the app-logs emptyDir"
  }
}

run "aci_agent_sidecar_sizing_override" {
  command = plan
  variables {
    apm           = null
    architecture  = "aci"
    runtime       = "python"
    agent_sidecar = { cpu = 0.5, memory_gb = 1, hostname = "ci-partner-sim-dev", image = "ehacr.azurecr.io/datadog/agent:7.84.2" }
  }
  assert {
    condition     = output.aci_sidecar.containers[0].cpu == 0.5 && output.aci_sidecar.containers[0].memory == 1 && output.aci_sidecar.containers[0].image == "ehacr.azurecr.io/datadog/agent:7.84.2" && output.aci_sidecar.containers[0].environment_variables["DD_HOSTNAME"] == "ci-partner-sim-dev"
    error_message = "agent_sidecar overrides sizing, image (e.g. an ACR mirror) and hostname"
  }
}

run "aci_fluent_bit_direct_fallback" {
  command = plan
  variables {
    apm          = null
    architecture = "aci"
    runtime      = "python"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "x", forward_port = 24224, sidecar_config = "service: {}\n", sidecar_parsers = "p", sidecar_lua = "l" }
      env          = { fleet = { EH_LOG_PIPELINE = "fluent_bit_direct" } }
    }
  }
  assert {
    condition     = jsonencode([for c in output.aci_sidecar.containers : c.name]) == jsonencode(["datadog-agent", "fluent-bit", "dsv-fetch"]) && output.log_collector == "fluent-bit-sidecar"
    error_message = "fallback: Fluent Bit collects the logs; the Agent sidecar keeps traces / DogStatsD; dsv-fetch refresher writes the Fluent Bit key"
  }
  assert {
    condition     = !yamldecode(output.aci_agent_files["datadog.yaml"]).logs_enabled && output.aci_agent_files.env["DD_LOGS_ENABLED"] == "false" && !strcontains(output.aci_agent_files.start, "app-logs.yaml")
    error_message = "one collector per log source: Agent log collection off when Fluent Bit collects"
  }
  assert {
    condition     = jsonencode(output.aci_sidecar.containers[2].commands) == jsonencode(["/opt/dsv-fetch/dsv-fetch", "init", "--out", "/dsv-secrets", "--format", "env-yaml", "--env-yaml-name", "fluentbit-env.yaml", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key#value", "--refresh-seconds", "3600", "--retry-seconds", "30"])
    error_message = "the refresher is the dsv-fetch binary in loop mode (ACI init containers have no managed identity)"
  }
  assert {
    condition     = output.aci_sidecar.containers[1].volumes[1].secret["fluent-bit.yaml"] == base64encode("service: {}\n")
    error_message = "ACI secret volume carries the Fluent Bit config files"
  }
}

run "aci_op_mode_without_worker_url_warns" {
  command = plan
  variables {
    apm          = null
    architecture = "aci"
    runtime      = "python"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "x", forward_port = 24224 }
    }
  }
  expect_failures = [check.datadog_sidecar_inputs]
  assert {
    condition     = !yamldecode(output.aci_agent_files["datadog.yaml"]).logs_enabled && output.apm.method == "agent_sidecar"
    error_message = "no OP Worker URL: no direct-to-intake bypass (logs off + plan warning); traces / DogStatsD still work"
  }
}

run "vm_host_route" {
  command = plan
  variables {
    architecture  = "vm"
    runtime       = "python"
    log_file_path = "/var/log/enterprise-hello/hello-worker.log"
  }
  assert {
    condition     = output.env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://localhost:4317" && output.env["LOG_FILE_PATH"] == "/var/log/enterprise-hello/hello-worker.log"
    error_message = "VM uses the local Agent OTLP receiver and a tailed log file."
  }
}

run "browser_only_unified_tags" {
  command = plan
  variables {
    runtime      = "browser"
    architecture = "aca"
    service = {
      service     = "hello-frontend"
      env         = "dev"
      version     = "2.0.0"
      team        = "web"
      owner       = "web@example.com"
      domain      = "storefront"
      tier        = "high"
      application = "enterprise-hello"
      region      = "swedencentral"
    }
  }
  assert {
    condition     = jsonencode(output.env) == jsonencode({ DD_ENV = "dev", DD_SERVICE = "hello-frontend", DD_SITE = "datadoghq.eu", DD_VERSION = "2.0.0" })
    error_message = "Browser runtime only gets RUM unified tags (no DSV env, no sidecar)."
  }
  assert {
    condition     = output.rum_global_context["team"] == "web" && output.rum_global_context["owner"] == "web_example.com" && !contains(keys(output.rum_global_context), "env")
    error_message = "RUM global context carries the non-unified policy tags"
  }
}

run "tag_policy_on_every_path" {
  command = plan
  variables {
    architecture = "aca"
    runtime      = "python"
    tag_policy = {
      apiVersion = "observability/tag-policy/v1"
      kind       = "TagPolicy"
      keys = {
        env         = { required = true, aliases = ["environment"], value_map = { development = "dev" } }
        service     = { required = true, otel_attributes = ["service.name"] }
        version     = { required = true, otel_attributes = ["service.version"] }
        team        = { required = true, key = "owning_team" }
        application = { required = true }
      }
      static_tags = { business_unit = "retail" }
    }
    service = {
      service     = "hello-orders-api"
      env         = "Development"
      version     = "1.4.2"
      team        = "orders"
      application = "enterprise-hello"
    }
  }
  assert {
    condition     = output.env["DD_ENV"] == "dev" && output.env["DD_TAGS"] == "application:enterprise-hello,business_unit:retail,environment:dev,owning_team:orders"
    error_message = "DD_ENV after value_map; DD_TAGS = every non-unified tag incl. alias, rename and static tag"
  }
  assert {
    condition     = strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "environment=dev") && strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "owning_team=orders") && strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "service.name=hello-orders-api") && strcontains(output.env["OTEL_RESOURCE_ATTRIBUTES"], "cloud.platform=azure_container_apps")
    error_message = "OTEL_RESOURCE_ATTRIBUTES from the policy + cloud attributes"
  }
  assert {
    condition     = one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_TAGS"]) == "application:enterprise-hello,business_unit:retail,environment:dev,owning_team:orders" && one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_ENV"]) == "dev"
    error_message = "serverless-init sidecar tags = the policy tag set (unified + DD_TAGS)"
  }
  assert {
    condition     = output.azure_tags["owning_team"] == "orders" && output.azure_tags["env"] == "dev"
    error_message = "Azure resource tags from the same policy"
  }
}

run "aks_labels_and_tag_annotation" {
  command = plan
  assert {
    condition     = output.k8s_patch_object.spec.template.metadata.labels["tags.datadoghq.com/env"] == "dev" && output.k8s_patch_object.spec.template.metadata.labels["team"] == "orders"
    error_message = "pod labels: unified service tags + label-safe policy tags"
  }
  assert {
    condition     = jsondecode(output.k8s_patch_object.spec.template.metadata.annotations["ad.datadoghq.com/tags"])["owner"] == "orders-team_example.com"
    error_message = "pod annotation ad.datadoghq.com/tags carries every non-unified tag (owner is not label-safe before normalisation)"
  }
}

run "datadog_mode_aks_ssi" {
  command = plan
  variables {
    apm = null
  }
  assert {
    condition     = output.apm.mode == "datadog" && output.apm.method == "ssi_kubernetes" && output.log_collector == "datadog-agent"
    error_message = "default fleet policy on AKS: SSI tracer + Agent log collection (-> Observability Pipelines)"
  }
  assert {
    condition     = output.env["TELEMETRY_SDK"] == "datadog" && output.env["DD_TRACE_OTEL_ENABLED"] == "true" && length([for k in keys(output.env) : k if startswith(k, "OTEL_")]) == 0 && output.env["DD_DOGSTATSD_PORT"] == "8125" && strcontains(output.env["DD_TAGS"], "team:")
    error_message = "datadog mode: no OTLP exporter env, OTel SDK disabled (never two tracers)"
  }
  assert {
    condition     = output.env["DD_PROFILING_ENABLED"] == "auto" && output.env["DD_PROFILING_EXCEPTION_ENABLED"] == "true" && output.profiling.enabled
    error_message = ".NET profiler on under SSI (auto)"
  }
  assert {
    condition     = output.k8s_patch_object.spec.template.metadata.labels["admission.datadoghq.com/enabled"] == "true" && jsondecode(output.k8s_patch_object.spec.template.metadata.annotations["ad.datadoghq.com/hello-orders-api.logs"])[0].source == "csharp"
    error_message = "admission controller label + Agent log source annotation"
  }
  assert {
    condition     = output.env["DD_DATA_STREAMS_ENABLED"] == "true" && output.env["DD_DBM_PROPAGATION_MODE"] == "full" && output.env["DD_LOGS_INJECTION"] == "true"
    error_message = "DSM (.NET Service Bus), DBM propagation, log injection"
  }
}

run "datadog_mode_aca_dotnet_agent_gateway" {
  command = plan
  variables {
    # per-workload opt-out of the aca default (serverless_init) for traces and logs (Container Apps jobs pattern)
    apm          = { managed_runtime_path = "agent_gateway" }
    logs         = { collector = "azure" }
    architecture = "aca"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "opw.internal", forward_port = 24224, sidecar_mode = "forward", sidecar_forward_config = "service: {}\n", sidecar_parsers = "p", sidecar_lua = "l" }
      env          = { apm_gateway = { DD_TRACE_AGENT_URL = "http://eh-obs-dev-apm:8126" } }
    }
  }
  assert {
    condition     = output.apm.method == "agent_gateway" && output.apm.ready && output.env["DD_TRACE_AGENT_URL"] == "http://eh-obs-dev-apm:8126"
    error_message = "managed runtime: tracer -> APM gateway from the contract"
  }
  assert {
    condition     = output.env["CORECLR_ENABLE_PROFILING"] == "1" && output.env["CORECLR_PROFILER_PATH"] == "/opt/datadog/linux-x64/Datadog.Trace.ClrProfiler.Native.so" && output.env["DD_PROFILING_ENABLED"] == "true"
    error_message = ".NET CLR profiler env for the image-installed tracer; profiler enabled"
  }
  assert {
    condition     = length(output.container_app_patch.sidecars) == 0 && length(output.container_app_patch.init_containers) == 0 && length(output.app_requirements) > 0 && output.log_route == "eventhub" && output.log_collector == "diagnostic-settings" && !contains(keys(output.env), "LOG_FILE_PATH")
    error_message = "no sidecar on the agent_gateway + azure logs path (console logs -> diagnostic settings); app requirements reported"
  }
}

run "datadog_mode_aca_default_serverless_init" {
  command = plan
  variables {
    apm                = null
    architecture       = "aca"
    identity_client_id = "33333333-3333-3333-3333-333333333333"
    serverless_init    = { subscription_id = "00000000-0000-0000-0000-000000000000", resource_group = "rg-app" }
  }
  assert {
    condition     = output.apm.mode == "datadog" && output.apm.method == "serverless_init" && !contains(keys(output.env), "DD_TRACE_AGENT_URL")
    error_message = "Container Apps default in datadog mode: serverless-init sidecar (tracer -> localhost:8126)"
  }
  assert {
    condition     = output.env["DD_DOGSTATSD_URL"] == "udp://localhost:8125" && output.env["DD_RUNTIME_METRICS_ENABLED"] == "true"
    error_message = "DogStatsD (custom + runtime metrics) to the serverless-init sidecar on localhost"
  }
  assert {
    condition     = jsonencode([for c in output.container_app_patch.sidecars : c.name]) == jsonencode(["datadog"]) && output.container_app_patch.sidecars[0].image == "datadog/serverless-init:1.10.4" && output.log_collector == "serverless-init"
    error_message = "one pinned serverless-init sidecar; no Fluent Bit sidecar"
  }
  assert {
    condition     = length(flatten([for c in output.container_app_patch.sidecars : [for e in c.env : e if e.name == "DD_API_KEY" || e.secret_name != null]])) == 0 && length(output.container_app_patch.secrets) == 0
    error_message = "no API key value or Container Apps secret anywhere"
  }
  assert {
    condition = alltrue([
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_LOGS_ENABLED"]) == "true",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_SERVERLESS_LOG_PATH"]) == "/var/log/app/app.log",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_SOURCE"]) == "csharp",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_SERVICE"]) == "hello-orders-api",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED"]) == "true",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL"]) == "http://opw.internal.example:8282",
      one([for e in output.container_app_patch.sidecars[0].env : e.value if e.name == "AZURE_CLIENT_ID"]) == "33333333-3333-3333-3333-333333333333",
      contains([for m in output.container_app_patch.sidecars[0].volume_mounts : m.name], "app-logs"),
      contains([for m in output.container_app_patch.app_container.volume_mounts : m.name], "app-logs"),
      output.env["LOG_FILE_PATH"] == "/var/log/app/app.log",
    ])
    error_message = "serverless-init tails the shared app log file and ships it to the OP Worker; DSV env for its dsv-fetch run"
  }
  assert {
    condition     = jsonencode(output.container_app_patch.sidecars[0].command) == jsonencode(["/bin/sh", "-c", "/eh/dsv-bin/dsv-fetch init --out /tmp/dsv-fetch --format dotenv --dotenv-name serverless-init.env --map DD_API_KEY=dsv://eh/dev/datadog-api-key#value && set -a && . /tmp/dsv-fetch/serverless-init.env && set +a && : > /tmp/dsv-fetch/serverless-init.env && exec /datadog-init"])
    error_message = "the sidecar resolves DD_API_KEY with the dsv-fetch binary into its own /tmp, sources and truncates the dotenv, then execs /datadog-init"
  }
  assert {
    condition     = jsonencode([for c in output.container_app_patch.init_containers : c.name]) == jsonencode(["dsv-fetch-install"]) && join(" ", output.container_app_patch.init_containers[0].args) == "install --dest /eh/dsv-bin/dsv-fetch" && !output.container_app_patch.init_containers[0].needs_identity && length(output.container_app_patch.refresher_containers) == 0
    error_message = "one identity-free init container installs the binary (every workload profile); no refresher"
  }
  assert {
    condition     = jsonencode(sort([for v in output.container_app_patch.volumes : v.name])) == jsonencode(["app-logs", "dsv-bin"]) && !strcontains(jsonencode(output.container_app_patch), "python")
    error_message = "EmptyDir app-logs + dsv-bin only; no dsv-secrets volume; no Python"
  }
}

run "datadog_mode_aca_serverless_init_replaces_fluent_bit_in_op_mode" {
  command = plan
  variables {
    apm          = null
    architecture = "aca"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "opw.internal", forward_port = 24224, sidecar_mode = "forward", sidecar_forward_config = "service: {}\n", sidecar_parsers = "p", sidecar_lua = "l" }
      aggregator   = { kind = "observability_pipelines", agent_logs_url = "http://opw.internal:8282" }
      env          = {}
    }
  }
  assert {
    condition     = jsonencode([for c in output.container_app_patch.init_containers : c.name]) == jsonencode(["dsv-fetch-install"]) && jsonencode([for c in output.container_app_patch.sidecars : c.name]) == jsonencode(["datadog"]) && length(output.sidecar_secret_refs) == 0
    error_message = "Observability Pipelines mode: no Fluent Bit sidecar (even with a forward config in the contract); serverless-init collects"
  }
}

run "appservice_datadog_mode_defaults_to_otel" {
  command = plan
  variables {
    apm          = null
    architecture = "appservice"
  }
  assert {
    condition     = output.apm.requested_mode == "otel" && output.apm.mode == "otel" && output.app_settings["TELEMETRY_SDK"] == "otel" && !contains(keys(output.app_settings), "DD_DOGSTATSD_URL")
    error_message = "App Service: fleet policy architectures.appservice = otel (no Datadog sidecar integration; the APM gateway path has no DogStatsD)"
  }
}

run "appservice_datadog_mode_per_workload" {
  command = plan
  variables {
    apm          = { mode = "datadog" }
    architecture = "appservice"
  }
  assert {
    condition     = output.apm.mode == "datadog" && output.apm.method == "agent_gateway" && output.app_settings["DD_RUNTIME_METRICS_ENABLED"] == "false"
    error_message = "per-workload opt-in: Datadog tracer -> APM gateway (no DogStatsD, runtime metrics off)"
  }
}

run "functions_exception_stays_otel" {
  command = plan
  variables {
    apm          = null
    architecture = "functions"
  }
  assert {
    condition     = output.apm.mode == "otel" && output.env["TELEMETRY_SDK"] == "otel" && !output.profiling.enabled && !contains(keys(output.env), "DD_PROFILING_ENABLED") && !contains(keys(output.env), "DD_DOTNET_TRACER_HOME")
    error_message = "Functions / Durable Functions exception: OpenTelemetry (Datadog documents neither the Functions host nor Durable V2 spans); no Datadog profiler"
  }
}

run "datadog_mode_windows_vm_otel_fallback" {
  command = plan
  variables {
    apm          = null
    architecture = "vm"
    os_type      = "windows"
  }
  assert {
    condition     = output.apm.mode == "otel" && output.env["TELEMETRY_SDK"] == "otel" && strcontains(output.apm.fallback_reason, "Windows")
    error_message = "Windows VMs stay on OpenTelemetry (documented fallback)"
  }
}

run "contract_fleet_switch" {
  command = plan
  variables {
    apm = null
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "x", forward_port = 24224 }
      env          = { fleet = { EH_APM_MODE = "otel", EH_LOG_PIPELINE = "fluent_bit_direct" } }
    }
  }
  assert {
    condition     = output.apm.mode == "otel" && output.log_pipeline == "fluent_bit_direct" && output.log_collector == "fluent-bit"
    error_message = "lab-wide switches from the transport contract env.fleet"
  }
}

run "contract_datadog_switch_keeps_architecture_exceptions" {
  command = plan
  variables {
    apm          = null
    architecture = "functions"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "x", forward_port = 24224 }
      env          = { fleet = { EH_APM_MODE = "datadog", EH_LOG_PIPELINE = "observability_pipelines" } }
    }
  }
  assert {
    condition     = output.apm.mode == "otel" && output.log_pipeline == "observability_pipelines"
    error_message = "env-wide EH_APM_MODE = datadog does not override the functions exception (OpenTelemetry)"
  }
}

run "contract_datadog_switch_aca_serverless_init" {
  command = plan
  variables {
    apm          = null
    architecture = "aca"
    telemetry = {
      datadog_site = "datadoghq.eu"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
      otlp         = { grpc_endpoint = "http://gw:4317", http_endpoint = "http://gw:4318" }
      fluentbit    = { forward_host = "x", forward_port = 24224, sidecar_mode = "forward", sidecar_forward_config = "service: {}\n", sidecar_parsers = "p", sidecar_lua = "l" }
      aggregator   = { kind = "observability_pipelines", agent_logs_url = "http://opw:8282" }
      env          = { fleet = { EH_APM_MODE = "datadog" } }
    }
  }
  assert {
    condition     = output.apm.mode == "datadog" && output.apm.method == "serverless_init"
    error_message = "lab contract switch datadog on Container Apps: serverless-init by default"
  }
}
