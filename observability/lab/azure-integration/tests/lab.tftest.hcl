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
  mock_resource "datadog_dashboard_json" {
    defaults = { url = "/dashboard/abc-def-ghi" }
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

run "log_management_defaults" {
  command = plan
  assert {
    condition     = length(output.azure_log_metrics) == 8 && module.log_management.index_name == null && module.log_management.pipeline_id == null && output.azure_logs_dashboard_url == "/dashboard/abc-def-ghi"
    error_message = "Lab: dashboard + log-based metrics; index and pipeline (org-wide objects) stay opt-in."
  }
}

run "native_mode_logs_off_by_default" {
  command = plan
  variables {
    settings = { mode = "native", native_monitor_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.Datadog/monitors/dd" }
  }
  assert {
    condition     = length(output.native_log_forwarding.subscription_log_subscription_ids) == 0 && length(output.native_log_forwarding.resource_log_subscription_ids) == 0 && !output.native_log_forwarding.aad_logs
    error_message = "Native mode in the lab forwards no logs (Event Hubs path is authoritative)."
  }
}

run "native_logs_instead_of_event_hubs" {
  command = plan
  variables {
    settings = {
      mode                    = "native"
      native_monitor_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.Datadog/monitors/dd"
      native_logs             = { subscription_logs = true, tag_filters = [{ name = "application", value = "enterprise-hello" }] }
      eventhub_log_forwarding = { activity_logs = false }
    }
  }
  assert {
    condition     = jsonencode(output.native_log_forwarding.subscription_log_subscription_ids) == jsonencode(["00000000-0000-0000-0000-000000000000"])
    error_message = "Native Activity Log forwarding when the Event Hubs Activity Log export is off."
  }
}

run "reject_native_and_eventhub_activity_log" {
  command = plan
  variables {
    settings = {
      mode              = "native"
      native_monitor_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.Datadog/monitors/dd"
      native_logs       = { subscription_logs = true }
    }
  }
  expect_failures = [var.settings]
}
