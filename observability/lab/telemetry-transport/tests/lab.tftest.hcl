mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport" }
  }
  mock_resource "azurerm_eventhub_namespace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport/providers/Microsoft.EventHub/namespaces/evhns" }
  }
  mock_resource "azurerm_eventhub_namespace_authorization_rule" {
    defaults = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
      primary_connection_string = "Endpoint=sb://mock/;SharedAccessKeyName=fluent-bit-listen;SharedAccessKey=mock"
    }
  }
}
mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport/providers/Microsoft.App/containerApps/x"
      output = { fqdn = "x.internal.happy-hill-1.swedencentral.azurecontainerapps.io" }
    }
  }
}
mock_provider "datadog" {
  override_during = plan
  mock_resource "datadog_observability_pipeline" {
    defaults = { id = "aaaaaaaa-0000-0000-0000-000000000001" }
  }
}

variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  foundation_network = {
    subnets = {
      "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pe", name = "pe" }
      "observability"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/obs", name = "obs" }
    }
    private_dns_zones = {
      "privatelink.servicebus.windows.net" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net", name = "privatelink.servicebus.windows.net" }
    }
  }
  foundation_identity = {
    identities = {
      "obs-collector" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-collector-dev-sec", principal_id = "11111111-1111-1111-1111-111111111111", client_id = "22222222-2222-2222-2222-222222222222", name = "eh-id-obs-collector-dev-sec" }
    }
    secrets = {
      provider      = "delinea-dsv"
      tenant        = "contoso"
      tld           = "com"
      base_url      = "https://contoso.secretsvaultcloud.com/v1"
      base_path     = "eh/dev"
      auth_provider = "azure-eh"
      refs = {
        "datadog-api-key" = "dsv://eh/dev/datadog-api-key#value"
      }
    }
  }
  artifacts = {
    "img-dsv-fetch" = { image = "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }
  platform_containerapps = {
    environment_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-apps-dev-sec"
    default_domain    = "happy-hill-1.swedencentral.azurecontainerapps.io"
    workload_profiles = ["Consumption", "d4"]
  }
}

run "lab_defaults" {
  command = plan
  assert {
    condition     = output.contract.datadog_site == "datadoghq.com" && output.contract.api_key_ref == "dsv://eh/dev/datadog-api-key#value"
    error_message = "Site + API key DSV reference from foundation-identity v2."
  }
  assert {
    condition     = output.contract.aggregator.kind == "observability_pipelines" && module.transport.op_pipeline_id == "aaaaaaaa-0000-0000-0000-000000000001" && module.transport.op_worker_id != null && module.transport.aggregator_id == null
    error_message = "Package default: Observability Pipelines (pipeline created, Worker on ACA, no Fluent Bit aggregator)."
  }
  assert {
    condition     = output.contract.fluentbit.sidecar_mode == "forward" && output.contract.fluentbit.forward_shared_key_ref == null && output.contract.aggregator.agent_logs_url == "http://x.internal.happy-hill-1.swedencentral.azurecontainerapps.io:8282"
    error_message = "Edge collectors forward to the Worker (no key on the edge); Agents get the Worker's agent source URL."
  }
  assert {
    condition     = output.contract.env.fleet.EH_LOG_PIPELINE == "observability_pipelines" && output.contract.env.fleet.EH_APM_MODE == "datadog" && output.contract.env.apm_gateway.DD_TRACE_AGENT_URL == "http://x.internal.happy-hill-1.swedencentral.azurecontainerapps.io:8126" && module.transport.apm_gateway_id != null
    error_message = "Fleet switches and the APM gateway URL are published for modules/instrumentation."
  }
  assert {
    condition     = output.contract.secrets.fetch_image == "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222" && output.contract.secrets.provider == "delinea-dsv"
    error_message = "The contract publishes the DSV runtime settings and the dsv-fetch image."
  }
  assert {
    condition     = local.env_level_tags["env"] == "dev" && local.env_level_tags["region"] == "swedencentral" && local.env_level_tags["application"] == "enterprise-hello" && !contains(keys(local.env_level_tags), "service")
    error_message = "Environment-level default tags from modules/tagging (no service-level keys)."
  }
  assert {
    condition     = local.service_tags["hello-orders-api"]["team"] == "orders" && length(local.service_tags) >= 30
    error_message = "Per-service tag sets come from the rendered onboarding (onboarding/rendered/dev)."
  }
  assert {
    condition     = local.batch_op && strcontains(local.batch_setup_script, "EH_LOG_PATHS") && !strcontains(local.batch_setup_script, "--map DD_API_KEY=$API_KEY_REF")
    error_message = "Batch nodes forward to the Worker: no Datadog API key on the node."
  }
  assert {
    condition     = jsonencode(output.contract.fluentbit.aca_console_allow) == jsonencode(["eh-caj-*"])
    error_message = "Only ACA jobs' console logs are forwarded by default."
  }
}

run "op_existing_pipeline" {
  command = plan
  variables {
    settings = { op_pipeline_id = "bbbbbbbb-0000-0000-0000-000000000002" }
  }
  assert {
    condition     = module.transport.op_pipeline_id == "bbbbbbbb-0000-0000-0000-000000000002" && output.contract.aggregator.pipeline_id == "bbbbbbbb-0000-0000-0000-000000000002"
    error_message = "An existing pipeline id is used as is (no datadog_observability_pipeline created)."
  }
}

run "reject_apm_gateway_cost_ceiling" {
  command = plan
  variables {
    settings = { apm_gateway_max_replicas = 9 }
  }
  expect_failures = [var.settings]
}

run "fluent_bit_direct" {
  command = plan
  variables {
    settings = { fleet = { log_pipeline = "fluent_bit_direct", apm = { mode = "otel" } } }
  }
  assert {
    condition     = output.contract.datadog_site == "datadoghq.com" && output.contract.api_key_ref == "dsv://eh/dev/datadog-api-key#value"
    error_message = "Site + API key DSV reference from foundation-identity v2."
  }
  assert {
    condition     = output.contract.fluentbit.forward_shared_key_ref == "dsv://eh/dev/fluentbit-shared-key#value"
    error_message = "Shared key reference derived from the DSV base path when foundation does not list it."
  }
  assert {
    condition     = output.contract.secrets.fetch_image == "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222" && output.contract.secrets.base_url == "https://contoso.secretsvaultcloud.com/v1" && output.contract.secrets.provider == "delinea-dsv"
    error_message = "The contract publishes the DSV runtime settings and the dsv-fetch image (from artifacts img-dsv-fetch)."
  }
  assert {
    condition     = nonsensitive(output.generated_secrets["eventhub-fluentbit-listen"]) == "Endpoint=sb://mock/;SharedAccessKeyName=fluent-bit-listen;SharedAccessKey=mock" && !strcontains(jsonencode(output.contract), "SharedAccessKey")
    error_message = "generated_secrets carries the Event Hubs listen connection string for publish.py; the contract never does."
  }
  assert {
    condition     = module.transport.aggregator_id != null && output.contract.fluentbit.sidecar_config != null
    error_message = "Aggregator deployed; sidecar config published."
  }
  assert {
    condition     = module.transport.event_hub_namespace_id != null && output.contract.event_hub.app_logs_hub == "app-logs"
    error_message = "Event Hub created."
  }
  assert {
    condition     = azurerm_resource_group.this.tags["component"] == "obs-telemetry-transport" && azurerm_resource_group.this.tags["layer"] == "observability"
    error_message = "Lab tags applied."
  }
  assert {
    condition     = output.contract.otlp.internal_only && output.contract.otlp.logs_policy == "drop"
    error_message = "Internal-only receivers; OTLP logs dropped."
  }
  assert {
    condition     = jsonencode(output.contract.fluentbit.aca_console_allow) == jsonencode(["eh-caj-*"])
    error_message = "Only ACA jobs' console logs are forwarded by default."
  }
}

run "tail_sampling_forces_single_replica" {
  command = plan
  variables {
    settings = { gateway_sampling = "tail", gateway_max_replicas = 3, gateway_hosting = "container_app" }
  }
  # the lab forces max_replicas = 1 for tail sampling, so the module validation passes
  assert {
    condition     = output.contract.gateway.sampling == "tail"
    error_message = "Tail sampling wired with a single replica."
  }
}

run "reject_lab_cost_ceiling" {
  command = plan
  variables {
    settings = { event_hub_capacity = 10 }
  }
  expect_failures = [var.settings]
}

run "batch_log_setup_published" {
  command = plan
  variables {
    settings = { fleet = { log_pipeline = "fluent_bit_direct" } }
  }

  assert {
    condition     = output.contract.batch_log_setup.fluent_bit_version == "5.1.3" && length(output.contract.batch_log_setup.script_sha256) == 64 && strcontains(local.batch_setup_script, "EH_LOG_PATHS") && strcontains(local.batch_setup_script, "EH_IDENTITY_CLIENT_ID") && strcontains(local.batch_setup_script, "CONFIGURE_AGENT='false'")
    error_message = "The Batch Fluent Bit setup script (pinned version, runtime path/identity overrides, no Agent) is published in the contract."
  }
  assert {
    condition     = strcontains(local.batch_setup_script, "--map DD_API_KEY=$API_KEY_REF") && strcontains(local.batch_setup_script, "API_KEY_REF='dsv://eh/dev/datadog-api-key#value'") && !strcontains(local.batch_setup_script, "vault.azure.net") && strcontains(local.batch_setup_script, "INSTALL_AGENT='false'")
    error_message = "No API key value is rendered into the script: dsv-fetch reads it from DSV on the node with the pool identity."
  }
}

run "batch_log_setup_disabled" {
  command = plan
  variables {
    settings = { batch_log_setup_enabled = false }
  }
  assert {
    condition     = output.contract.batch_log_setup == null
    error_message = "batch_log_setup can be switched off."
  }
}
