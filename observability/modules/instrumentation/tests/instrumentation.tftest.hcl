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
    runtime            = "python"
    architecture       = "aca"
    identity_client_id = "33333333-3333-3333-3333-333333333333"
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

run "aci_sidecar_spec" {
  command = plan
  variables {
    architecture = "aci"
    runtime      = "python"
  }
  assert {
    condition     = length(output.aci_sidecar.container.secure_environment_variables) == 0 && output.aci_sidecar.fetcher.name == "dsv-fetch" && contains(output.aci_sidecar.fetcher.commands, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value") && output.aci_sidecar.fetcher.commands[0] == "/usr/bin/python3.13"
    error_message = "ACI: no secure env values; a dsv-fetch refresher container (ACI init containers have no managed identity) writes the env file."
  }
  assert {
    condition     = anytrue([for v in output.aci_sidecar.container.volumes : v.name == "dsv-secrets" && v.empty_dir && v.mount_path == "/dsv-secrets"])
    error_message = "ACI: Fluent Bit mounts the shared emptyDir with the env file."
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
    error_message = "Browser runtime only gets RUM unified tags (no DSV env, no sidecar)."
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
      datadog_site = "datadoghq.com"
      api_key_ref  = "0123456789abcdef0123456789abcdef"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1" }
      otlp         = { grpc_endpoint = "", http_endpoint = "" }
      fluentbit    = { forward_host = "x", forward_port = 24224 }
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

run "reject_aca_without_fetch_image" {
  command = plan
  variables {
    architecture = "aca"
    telemetry = {
      datadog_site = "datadoghq.com"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { base_url = "https://contoso.secretsvaultcloud.com/v1" }
      otlp         = { grpc_endpoint = "", http_endpoint = "" }
      fluentbit    = { forward_host = "x", forward_port = 24224 }
    }
  }
  expect_failures = [var.telemetry]
}

run "aks_env_has_dsv_defaults_and_no_secrets" {
  command = plan
  variables {
    identity_client_id = "44444444-4444-4444-4444-444444444444"
  }
  assert {
    condition     = output.env["DSV_BASE_URL"] == "https://contoso.secretsvaultcloud.com/v1" && output.env["AZURE_CLIENT_ID"] == "44444444-4444-4444-4444-444444444444" && length(output.sidecar_secret_refs) == 0
    error_message = "AKS apps get the DSV env; no sidecar secrets."
  }
}
