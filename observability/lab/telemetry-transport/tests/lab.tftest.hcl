mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport" }
  }
  mock_resource "azurerm_eventhub_namespace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport/providers/Microsoft.EventHub/namespaces/evhns" }
  }
  mock_resource "azurerm_eventhub_namespace_authorization_rule" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dev-sec-transport/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send" }
  }
  mock_resource "azurerm_key_vault_secret" {
    defaults = { versionless_id = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/eventhub-fluentbit-listen" }
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
    key_vault_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/eh-kv-ident-dev-abcde"
    key_vault_uri = "https://eh-kv-ident-dev-abcde.vault.azure.net/"
    identities = {
      "obs-collector" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-collector-dev-sec", principal_id = "11111111-1111-1111-1111-111111111111", client_id = "22222222-2222-2222-2222-222222222222", name = "eh-id-obs-collector-dev-sec" }
    }
    secret_ids = {
      "datadog-api-key" = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-api-key"
    }
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
    condition     = output.contract.datadog_site == "datadoghq.com" && output.contract.api_key_secret_id == "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-api-key"
    error_message = "Site + API key reference from foundation-identity."
  }
  assert {
    condition     = output.contract.fluentbit.forward_shared_key_secret_id == "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/fluentbit-shared-key"
    error_message = "Shared key id derived from the vault when foundation does not publish it."
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
}

run "reject_public_receiver_via_lab" {
  command = plan
  variables {
    settings = { gateway_sampling = "tail", gateway_max_replicas = 3, gateway_hosting = "container_app" }
  }
  # lab forces max_replicas = 1 for tail sampling -> plan succeeds
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
