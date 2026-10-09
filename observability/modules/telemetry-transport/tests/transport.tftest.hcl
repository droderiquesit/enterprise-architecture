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
  mock_resource "azurerm_key_vault_secret" {
    defaults = {
      versionless_id = "https://kv-obs.vault.azure.net/secrets/eventhub-fluentbit-listen"
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
    site              = "datadoghq.eu"
    api_key_secret_id = "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
    env               = "dev"
    extra_tags        = { team = "observability" }
  }
  collector_identity = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs"
    principal_id = "11111111-1111-1111-1111-111111111111"
    client_id    = "22222222-2222-2222-2222-222222222222"
  }
  key_vault = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/kv-obs"
    grant_secrets_user = true
  }
  event_hub = {
    listen_secret_key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/kv-obs"
    private_endpoint = {
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/private-endpoints"
      private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
    }
  }
  container_apps = {
    environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/cae"
  }
  aggregator = {
    forward_shared_key_secret_id = "https://kv-obs.vault.azure.net/secrets/fluentbit-shared-key"
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
    condition     = anytrue([for s in azapi_resource.aggregator[0].body.properties.configuration.secrets : s.name == "eventhub-conn" && try(s.keyVaultUrl, "") == "https://kv-obs.vault.azure.net/secrets/eventhub-fluentbit-listen"])
    error_message = "Kafka credentials are a Key Vault reference."
  }
  assert {
    condition     = azapi_resource.gateway[0].body.properties.template.containers[0].image == "otel/opentelemetry-collector-contrib:0.162.0" && contains(azapi_resource.gateway[0].body.properties.template.containers[0].args, "--config=env:OTELCOL_CONFIG_SCRAPE_FLB")
    error_message = "Upstream gateway by default, scraping Fluent Bit self-metrics."
  }
  assert {
    condition     = length(azurerm_role_assignment.kv_secrets_user) == 1 && length(azurerm_private_endpoint.eventhub) == 1
    error_message = "KV role + Event Hubs private endpoint expected."
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
      mode                               = "existing"
      namespace_id                       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ent/providers/Microsoft.EventHub/namespaces/ent-logs"
      send_authorization_rule_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ent/providers/Microsoft.EventHub/namespaces/ent-logs/authorizationRules/diag"
      listen_connection_string_secret_id = "https://kv-ent.vault.azure.net/secrets/ent-logs-listen"
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
    condition     = !anytrue([for s in azapi_resource.aggregator[0].body.properties.configuration.secrets : s.name == "eventhub-conn"])
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
      auth         = { token_secret_id = "https://kv/secrets/t", client_headers_secret_id = "https://kv/secrets/h" }
    }
  }
  expect_failures = [var.gateway]
}

run "reject_versioned_or_literal_api_key" {
  command = plan
  variables {
    datadog = {
      site              = "datadoghq.com"
      api_key_secret_id = "https://kv-obs.vault.azure.net/secrets/datadog-api-key/0123456789abcdef0123456789abcdef"
      env               = "dev"
    }
  }
  expect_failures = [var.datadog]
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
}
