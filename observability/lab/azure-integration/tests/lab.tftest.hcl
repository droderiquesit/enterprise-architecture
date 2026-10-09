mock_provider "azurerm" {
  override_during = plan
  mock_data "azurerm_key_vault_secret" {
    defaults = { value = "mock-not-a-real-secret" }
  }
}
mock_provider "azapi" {
  override_during = plan
}
mock_provider "datadog" {
  override_during = plan
  mock_resource "datadog_integration_azure" {
    defaults = { id = "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111" }
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
  foundation_identity = { key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/eh-kv-ident-dev-abcde" }
}

run "default_without_app_is_none" {
  command = plan
  assert {
    condition     = output.mode == "none" && output.integration_id == null
    error_message = "Nothing deployed until the Entra app exists."
  }
}

run "app_registration" {
  command = plan
  variables {
    settings = {
      app_client_id            = "11111111-1111-1111-1111-111111111111"
      app_service_principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }
  assert {
    condition     = output.mode == "app_registration" && output.integration_id == "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111"
    error_message = "App registration integration with lab tag filter."
  }
}

run "secretless_reads_no_secret" {
  command = plan
  variables {
    settings = { app_client_id = "11111111-1111-1111-1111-111111111111", app_auth = "secretless" }
  }
  assert {
    condition     = length(data.azurerm_key_vault_secret.client_secret) == 0
    error_message = "Secretless auth needs no Key Vault read."
  }
}

run "reject_bad_mode" {
  command = plan
  variables {
    settings = { mode = "agentless" }
  }
  expect_failures = [var.settings]
}
