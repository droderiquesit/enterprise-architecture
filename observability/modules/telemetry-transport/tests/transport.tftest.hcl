mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_eventhub_namespace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/eh-obs-dev-evhns"
    }
  }
  mock_resource "azurerm_eventhub_namespace_authorization_rule" {
    defaults = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/eh-obs-dev-evhns/authorizationRules/diagnostic-settings-send"
      primary_connection_string = "Endpoint=sb://mock/;SharedAccessKeyName=x;SharedAccessKey=y"
    }
  }
  mock_resource "azurerm_eventhub" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/eh-obs-dev-evhns/eventhubs/app-logs"
    }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.App/containerApps/mock"
      output = { fqdn = "mock.internal.blue-sky-123.swedencentral.azurecontainerapps.io" }
    }
  }
}

variables {
  name_prefix    = "eh-obs-dev"
  resource_group = { name = "rg-obs", id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs" }
  location       = "swedencentral"
  tags           = { env = "dev" }
  datadog = {
    site        = "datadoghq.eu"
    api_key_ref = "dsv://eh/dev/datadog-api-key#value"
    env         = "dev"
    extra_tags  = { team = "observability" }
  }
  secrets = {
    tenant      = "contoso"
    fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  }
  collector_identity = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs"
    principal_id = "11111111-1111-1111-1111-111111111111"
    client_id    = "22222222-2222-2222-2222-222222222222"
  }
  event_hub = {
    listen_connection_string_ref = "dsv://eh/dev/eventhub-fluentbit-listen#value"
    private_endpoint = {
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/private-endpoints"
      private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
    }
  }
  container_apps = {
    environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/cae"
  }
  aggregator = {
    forward_shared_key_ref = "dsv://eh/dev/fluentbit-shared-key#value"
  }
}

run "default_create_everything_internal" {
  command = plan

  assert {
    condition     = azurerm_eventhub_namespace.this[0].sku == "Standard" && azurerm_eventhub_namespace.this[0].minimum_tls_version == "1.2"
    error_message = "Standard namespace (Kafka) with TLS 1.2 expected."
  }
  assert {
    condition     = azurerm_eventhub.hub["app"].partition_count == 2 && azurerm_eventhub.hub["platform"].message_retention == 1
    error_message = "Hubs: 2 partitions, 1 day retention."
  }
  assert {
    condition     = azurerm_eventhub_namespace_authorization_rule.fluentbit_listen[0].listen && !azurerm_eventhub_namespace_authorization_rule.fluentbit_listen[0].send && !azurerm_eventhub_namespace_authorization_rule.fluentbit_listen[0].manage
    error_message = "Fluent Bit rule must be listen-only."
  }
  assert {
    condition     = azurerm_eventhub_namespace.this[0].network_rulesets[0].default_action == "Deny" && azurerm_eventhub_namespace.this[0].network_rulesets[0].trusted_service_access_enabled
    error_message = "Namespace denies public traffic but allows trusted services (diagnostic settings)."
  }
  assert {
    condition     = azapi_resource.gateway[0].body.properties.configuration.ingress.external == false && alltrue([for m in azapi_resource.gateway[0].body.properties.configuration.ingress.additionalPortMappings : m.external == false])
    error_message = "Gateway receivers must be internal only."
  }
  assert {
    condition     = azapi_resource.aggregator[0].body.properties.configuration.ingress.external == false && azapi_resource.aggregator[0].body.properties.configuration.ingress.transport == "tcp"
    error_message = "Aggregator forward input must be internal TCP."
  }
  assert {
    condition     = output.contract.otlp.grpc_endpoint == "http://mock.internal.blue-sky-123.swedencentral.azurecontainerapps.io:4317" && output.contract.otlp.http_endpoint == "https://mock.internal.blue-sky-123.swedencentral.azurecontainerapps.io"
    error_message = "Contract OTLP endpoints derive from the gateway ingress FQDN."
  }
  assert {
    condition     = output.contract.event_hub.authorization_rule_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/eh-obs-dev-evhns/authorizationRules/diagnostic-settings-send"
    error_message = "Contract must expose the diagnostics send rule id."
  }
  assert {
    condition     = output.contract.fluentbit.logs_intake_host == "http-intake.logs.datadoghq.eu" && strcontains(output.contract.fluentbit.sidecar_config, "name: tail")
    error_message = "Contract carries the sidecar config and site-specific intake."
  }
  assert {
    condition     = !strcontains(jsonencode(output.contract), "SharedAccessKey=")
    error_message = "No secrets in the contract."
  }
  assert {
    condition = (strcontains(join(" ", azapi_resource.aggregator[0].body.properties.template.initContainers[0].args), "--format env-yaml")
      && contains(azapi_resource.aggregator[0].body.properties.template.initContainers[0].args, "EVENTHUB_CONNECTION_STRING=dsv://eh/dev/eventhub-fluentbit-listen#value")
      && contains(azapi_resource.aggregator[0].body.properties.template.initContainers[0].args, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value")
    && contains(azapi_resource.aggregator[0].body.properties.template.initContainers[0].args, "FLB_FORWARD_SHARED_KEY=dsv://eh/dev/fluentbit-shared-key#value"))
    error_message = "Aggregator: dsv-fetch init container writes DD_API_KEY, the shared key and the Kafka connection string into the env-yaml file."
  }
  assert {
    condition     = !strcontains(jsonencode(azapi_resource.aggregator[0].body), "keyVaultUrl") && !strcontains(jsonencode(azapi_resource.gateway[0].body), "keyVaultUrl") && !anytrue([for e in azapi_resource.aggregator[0].body.properties.template.containers[0].env : contains(["DD_API_KEY", "EVENTHUB_CONNECTION_STRING", "FLB_FORWARD_SHARED_KEY"], e.name)])
    error_message = "No Key Vault references and no secret env vars on the collectors."
  }
  assert {
    condition     = anytrue([for v in azapi_resource.aggregator[0].body.properties.template.volumes : v.name == "dsv-secrets" && v.storageType == "EmptyDir"]) && anytrue([for m in azapi_resource.aggregator[0].body.properties.template.containers[0].volumeMounts : m.volumeName == "dsv-secrets" && m.mountPath == "/dsv-secrets"])
    error_message = "The env file is shared through an EmptyDir mounted at /dsv-secrets."
  }
  assert {
    condition = (join(" ", azapi_resource.gateway[0].body.properties.template.initContainers[0].args) == "init --out /dsv-secrets --format files --file-mode 0444 --map dd-api-key=dsv://eh/dev/datadog-api-key#value"
      && anytrue([for e in azapi_resource.gateway[0].body.properties.template.initContainers[0].env : e.name == "AZURE_CLIENT_ID" && e.value == "22222222-2222-2222-2222-222222222222"])
    && anytrue([for e in azapi_resource.gateway[0].body.properties.template.initContainers[0].env : e.name == "DSV_BASE_URL" && e.value == "https://contoso.secretsvaultcloud.com/v1"]))
    error_message = "Gateway: dsv-fetch writes the API key FILE read by the file provider, authenticating with the collector identity."
  }
  assert {
    condition     = jsonencode(azapi_resource.gateway[0].body.properties.configuration.registries) == jsonencode([{ server = "ehacr.azurecr.io", identity = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs" }])
    error_message = "dsv-fetch is pulled from the private registry with the collector identity."
  }
  assert {
    condition     = nonsensitive(output.generated_secrets["eventhub-fluentbit-listen"]) == "Endpoint=sb://mock/;SharedAccessKeyName=x;SharedAccessKey=y" && output.contract.api_key_ref == "dsv://eh/dev/datadog-api-key#value" && output.contract.secrets.base_url == "https://contoso.secretsvaultcloud.com/v1"
    error_message = "The generated listen connection string is only a sensitive output (for publish.py -> DSV); the contract carries DSV refs."
  }
  assert {
    condition     = azapi_resource.gateway[0].body.properties.template.containers[0].image == "otel/opentelemetry-collector-contrib:0.162.0" && contains(azapi_resource.gateway[0].body.properties.template.containers[0].args, "--config=env:OTELCOL_CONFIG_SCRAPE_FLB")
    error_message = "Upstream gateway by default, scraping Fluent Bit self-metrics."
  }
  assert {
    condition     = !contains(azapi_resource.gateway[0].body.properties.template.containers[0].args, "--config=env:OTELCOL_CONFIG_LOGS_FORWARD")
    error_message = "OTLP logs (e.g. Functions host) are dropped by default."
  }
  assert {
    condition     = length(azurerm_private_endpoint.eventhub) == 1
    error_message = "Event Hubs private endpoint expected."
  }
}

run "ddot_tail_sampling_single_replica" {
  command = plan
  variables {
    gateway = {
      distribution = "ddot"
      sampling     = "tail"
      max_replicas = 1
    }
  }
  assert {
    condition     = azapi_resource.gateway[0].body.properties.template.containers[0].image == "datadog/ddot-collector:7.84.2" && azapi_resource.gateway[0].body.properties.template.containers[0].args[0] == "run"
    error_message = "DDOT image with the otel-agent run sub-command."
  }
  assert {
    condition     = contains(azapi_resource.gateway[0].body.properties.template.containers[0].args, "--config=env:OTELCOL_CONFIG_TAIL")
    error_message = "Tail sampling overlay expected."
  }
}

run "existing_event_hub_and_external_endpoints" {
  command = plan
  variables {
    event_hub = {
      mode                         = "existing"
      namespace_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ent/providers/Microsoft.EventHub/namespaces/ent-logs"
      send_authorization_rule_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ent/providers/Microsoft.EventHub/namespaces/ent-logs/authorizationRules/diag"
      listen_connection_string_ref = "dsv://ent/prod/ent-logs-listen#value"
    }
    gateway = {
      hosting            = "none"
      external_endpoints = { grpc_endpoint = "http://otel.corp.internal:4317", http_endpoint = "https://otel.corp.internal" }
    }
  }
  assert {
    condition     = length(azurerm_eventhub_namespace.this) == 0 && length(azapi_resource.gateway) == 0
    error_message = "Nothing created for existing namespace / external gateway."
  }
  assert {
    condition     = output.contract.event_hub.kafka_endpoint == "ent-logs.servicebus.windows.net:9093" && output.contract.otlp.grpc_endpoint == "http://otel.corp.internal:4317"
    error_message = "Existing endpoints flow into the contract."
  }
  assert {
    condition     = length(nonsensitive(output.generated_secrets)) == 0
    error_message = "Nothing generated for an existing namespace."
  }
}

run "no_event_hub_uses_forward_only_config" {
  command = plan
  variables {
    event_hub = { mode = "none" }
  }
  assert {
    condition     = output.contract.event_hub == null && output.contract.log_routes.appservice == "none"
    error_message = "Without Event Hub there is no eventhub route."
  }
  assert {
    condition     = !strcontains(join(" ", azapi_resource.aggregator[0].body.properties.template.initContainers[0].args), "EVENTHUB_CONNECTION_STRING")
    error_message = "No Kafka secret without Event Hub."
  }
}

run "reject_public_receivers" {
  command = plan
  variables {
    container_apps = {
      environment_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/cae"
      external_ingress = true
    }
  }
  expect_failures = [var.container_apps]
}

run "reject_tail_sampling_with_multiple_replicas" {
  command = plan
  variables {
    gateway = { sampling = "tail", max_replicas = 3 }
  }
  expect_failures = [var.gateway]
}

run "reject_ddot_with_bearer_auth" {
  command = plan
  variables {
    gateway = {
      distribution = "ddot"
      auth         = { token_ref = "dsv://eh/dev/otlp-bearer-token", client_headers_ref = "dsv://eh/dev/otlp-headers" }
    }
  }
  expect_failures = [var.gateway]
}

run "reject_literal_api_key" {
  command = plan
  variables {
    datadog = {
      site        = "datadoghq.com"
      api_key_ref = "0123456789abcdef0123456789abcdef"
      env         = "dev"
    }
  }
  expect_failures = [var.datadog]
}

run "reject_key_vault_style_reference" {
  command = plan
  variables {
    datadog = {
      site        = "datadoghq.com"
      api_key_ref = "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
      env         = "dev"
    }
  }
  expect_failures = [var.datadog]
}

run "bearer_auth_and_forward_tls_from_dsv" {
  command = plan
  variables {
    gateway = {
      auth = { token_ref = "dsv://eh/dev/otlp-bearer-token#value", client_headers_ref = "dsv://eh/dev/otlp-headers#value" }
    }
    aggregator = {
      forward_shared_key_ref = "dsv://eh/dev/fluentbit-shared-key#value"
      forward_tls            = { cert_ref = "dsv://eh/dev/flb-tls-crt#value", key_ref = "dsv://eh/dev/flb-tls-key#value" }
    }
  }
  assert {
    condition     = contains(azapi_resource.gateway[0].body.properties.template.initContainers[0].args, "otlp-bearer-token=dsv://eh/dev/otlp-bearer-token#value") && output.contract.otlp.headers_ref == "dsv://eh/dev/otlp-headers#value"
    error_message = "Bearer token file from DSV; clients get the header reference."
  }
  assert {
    condition     = length(azapi_resource.aggregator[0].body.properties.template.initContainers) == 2 && contains(azapi_resource.aggregator[0].body.properties.template.initContainers[1].args, "tls.key=dsv://eh/dev/flb-tls-key#value") && anytrue([for e in azapi_resource.aggregator[0].body.properties.template.containers[0].env : e.name == "FLB_FORWARD_TLS_CRT" && e.value == "/dsv-tls/tls.crt"])
    error_message = "Forward TLS cert/key are written as files by a second dsv-fetch init container."
  }
}

run "reject_without_fetch_image" {
  command = plan
  variables {
    secrets = { tenant = "contoso" }
  }
  expect_failures = [azapi_resource.aggregator, azapi_resource.gateway]
}

run "reject_aggregator_without_shared_key" {
  command = plan
  variables {
    aggregator = {}
  }
  expect_failures = [var.aggregator]
}

# The produced contract must be directly consumable by the instrumentation hook (app-owner side).
run "contract_feeds_instrumentation_hook" {
  command = plan
  module {
    source = "../instrumentation"
  }
  variables {
    service = {
      service = "hello-inventory-api"
      env     = "dev"
      version = "3.1.0"
      team    = "inventory"
    }
    runtime      = "dotnet"
    architecture = "aca"
    telemetry    = run.default_create_everything_internal.contract
  }
  assert {
    condition     = output.env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "https://mock.internal.blue-sky-123.swedencentral.azurecontainerapps.io" && length(output.container_app_patch.sidecars) == 1
    error_message = "Instrumentation must accept the contract as-is."
  }
  assert {
    condition     = anytrue([for s in output.container_app_patch.secrets : s.name == "flb-lua" && strcontains(s.value, "eh_redact")])
    error_message = "Sidecar Lua shipped from the contract."
  }
  assert {
    condition     = output.container_app_patch.init_containers[0].image == "ehacr.azurecr.io/dsv-fetch@sha256:1111111111111111111111111111111111111111111111111111111111111111" && output.env["DSV_TENANT"] == "contoso"
    error_message = "The contract's DSV settings drive the app's dsv-fetch init container and DSV env."
  }
}

run "activity_logs_hub_dedicated_and_shared" {
  command = plan
  assert {
    condition     = azurerm_eventhub.hub["activity"].name == "activity-logs" && length(azurerm_eventhub_consumer_group.fluentbit) == 3 && output.contract.event_hub.activity_logs_hub == "activity-logs"
    error_message = "Control-plane logs get their own hub + consumer group by default."
  }
  assert {
    condition     = anytrue([for e in azapi_resource.aggregator[0].body.properties.template.containers[0].env : e.name == "EVENTHUB_TOPICS" && try(e.value, "") == "app-logs,platform-logs,activity-logs"])
    error_message = "The aggregator consumes all three hubs."
  }
}

run "activity_logs_share_platform_hub" {
  command = plan
  variables {
    event_hub = {
      activity_logs_hub            = ""
      listen_connection_string_ref = "dsv://eh/dev/eventhub-fluentbit-listen#value"
    }
  }
  assert {
    condition     = length(azurerm_eventhub.hub) == 2 && output.contract.event_hub.activity_logs_hub == "platform-logs"
    error_message = "An empty activity_logs_hub shares the platform hub (no extra hub)."
  }
}
