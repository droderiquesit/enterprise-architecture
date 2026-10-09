# Plan-only tests of the pure instrumentation hook (no providers involved).
variables {
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
    datadog_site      = "datadoghq.eu"
    api_key_secret_id = "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
    otlp = {
      grpc_endpoint     = "http://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io:4317"
      http_endpoint     = "https://ca-otelgw.internal.example.swedencentral.azurecontainerapps.io"
      headers_secret_id = "https://kv-obs.vault.azure.net/secrets/otlp-headers"
    }
    fluentbit = {
      forward_host    = "ca-flb.internal.example.swedencentral.azurecontainerapps.io"
      forward_port    = 24224
      sidecar_config  = "service: {}\n"
      sidecar_parsers = "parsers: []\n"
      sidecar_lua     = "-- lua\n"
    }
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

run "aca_python_sidecar_direct_to_datadog" {
  command = plan
  variables {
    runtime               = "python"
    architecture          = "aca"
    key_vault_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-app"
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
    condition     = output.secret_env["OTEL_EXPORTER_OTLP_HEADERS"] == "https://kv-obs.vault.azure.net/secrets/otlp-headers"
    error_message = "OTLP auth header must be a secret reference."
  }
  assert {
    condition     = length(output.container_app_patch.sidecars) == 1 && output.container_app_patch.sidecars[0].image == "fluent/fluent-bit:5.1.3"
    error_message = "One pinned Fluent Bit sidecar expected."
  }
  assert {
    condition     = anytrue([for s in output.container_app_patch.secrets : s.name == "dd-api-key" && s.key_vault_secret_id == "https://kv-obs.vault.azure.net/secrets/datadog-api-key" && s.value == null && endswith(s.identity, "id-app")])
    error_message = "Datadog API key must be a Key Vault reference read with the app identity."
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
      datadog_site      = "datadoghq.com"
      api_key_secret_id = "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
      otlp = {
        grpc_endpoint = ""
        http_endpoint = "https://gw"
      }
      fluentbit = {
        forward_host                 = "ca-flb"
        forward_port                 = 24224
        sidecar_mode                 = "forward"
        sidecar_forward_config       = "service: {}\n"
        sidecar_parsers              = "parsers: []\n"
        sidecar_lua                  = "-- lua\n"
        forward_shared_key_secret_id = "https://kv-obs.vault.azure.net/secrets/flb-shared-key"
      }
    }
  }
  assert {
    condition     = anytrue([for e in output.container_app_patch.sidecars[0].env : e.name == "FLB_FORWARD_HOST" && e.value == "ca-flb"])
    error_message = "Forward mode must target the aggregator."
  }
  assert {
    condition     = !anytrue([for s in output.container_app_patch.secrets : s.name == "dd-api-key"]) && anytrue([for s in output.container_app_patch.secrets : s.name == "flb-forward-shared-key"])
    error_message = "Forward mode carries the shared key, not the Datadog API key."
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
    condition     = output.app_settings["OTEL_EXPORTER_OTLP_HEADERS"] == "@Microsoft.KeyVault(SecretUri=https://kv-obs.vault.azure.net/secrets/otlp-headers)"
    error_message = "Secrets must be Key Vault references in app settings."
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

run "aci_sidecar_spec" {
  command = plan
  variables {
    architecture = "aci"
    runtime      = "python"
  }
  assert {
    condition     = output.aci_sidecar.container.secure_environment_variables["DD_API_KEY"] == "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
    error_message = "ACI sidecar must list the API key as a secret reference to resolve."
  }
  assert {
    condition     = output.aci_sidecar.container.volumes[1].secret["fluent-bit.yaml"] == base64encode("service: {}\n")
    error_message = "ACI secret volume carries the config files."
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
      service = "hello-frontend"
      env     = "dev"
      version = "2.0.0"
      team    = "web"
    }
  }
  assert {
    condition     = jsonencode(output.env) == jsonencode({ DD_ENV = "dev", DD_SERVICE = "hello-frontend", DD_SITE = "datadoghq.eu", DD_VERSION = "2.0.0" })
    error_message = "Browser runtime only gets RUM unified tags."
  }
}

run "reject_unknown_runtime" {
  command = plan
  variables {
    runtime = "cobol"
  }
  expect_failures = [var.runtime]
}

run "reject_literal_api_key" {
  command = plan
  variables {
    telemetry = {
      datadog_site      = "datadoghq.com"
      api_key_secret_id = "0123456789abcdef0123456789abcdef"
      otlp              = { grpc_endpoint = "", http_endpoint = "" }
      fluentbit         = { forward_host = "x", forward_port = 24224 }
    }
  }
  expect_failures = [var.telemetry]
}

run "reject_bad_service_tag" {
  command = plan
  variables {
    service = {
      service = "Hello Orders"
      env     = "dev"
      version = "1"
      team    = "t"
    }
  }
  expect_failures = [var.service]
}
