mock_provider "datadog" {
  override_during = plan
  mock_resource "datadog_integration_azure" {
    defaults = { id = "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111" }
  }
}
mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_datadog_monitor" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.Datadog/monitors/dd"
      identity = { principal_id = "33333333-3333-3333-3333-333333333333", tenant_id = "00000000-0000-0000-0000-000000000000" }
    }
  }
}
mock_provider "azapi" {
  override_during = plan
}

variables {
  tenant_id        = "00000000-0000-0000-0000-000000000000"
  subscription_ids = ["aaaaaaaa-0000-0000-0000-000000000000", "bbbbbbbb-0000-0000-0000-000000000000"]
  metric_tag_filters = [
    { name = "application", value = "enterprise-hello" },
    { name = "datadog", value = "exclude", action = "Exclude" },
  ]
  app_registration = {
    client_id                   = "11111111-1111-1111-1111-111111111111"
    service_principal_object_id = "44444444-4444-4444-4444-444444444444"
  }
  client_secret = "mock-secret-not-real"
}

run "app_registration_mode" {
  command = plan
  assert {
    condition     = datadog_integration_azure.this[0].host_filters == "application:enterprise-hello,!datadog:exclude"
    error_message = "Tag filters must become Datadog host_filters (exclusions with !)."
  }
  assert {
    condition     = datadog_integration_azure.this[0].automute && datadog_integration_azure.this[0].resource_collection_enabled && !datadog_integration_azure.this[0].custom_metrics_enabled
    error_message = "Defaults: automute + resource collection on, custom metrics off."
  }
  assert {
    condition     = length(azurerm_role_assignment.app_monitoring_reader) == 2 && azurerm_role_assignment.app_monitoring_reader["bbbbbbbb-0000-0000-0000-000000000000"].scope == "/subscriptions/bbbbbbbb-0000-0000-0000-000000000000"
    error_message = "Monitoring Reader per subscription."
  }
  assert {
    condition     = output.integration_id == "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111" && length(azurerm_datadog_monitor.this) == 0
    error_message = "Integration id output; no native resources."
  }
}

run "secretless_needs_no_secret" {
  command = plan
  variables {
    client_secret = null
    app_registration = {
      client_id = "11111111-1111-1111-1111-111111111111"
      auth      = "secretless"
    }
  }
  assert {
    condition     = datadog_integration_azure.this[0].secretless_auth_enabled && datadog_integration_azure.this[0].client_secret == null
    error_message = "Secretless auth sends no secret."
  }
}

run "native_mode_new_monitor" {
  command = plan
  variables {
    mode = "native"
    native = {
      name                = "dd-eh-dev"
      resource_group_name = "rg-obs"
      location            = "swedencentral"
      user_name           = "Platform"
      user_email          = "platform-team@example.com"
    }
    native_org_keys = { api_key = "mock", application_key = "mock" }
  }
  assert {
    condition     = azurerm_datadog_monitor_tag_rule.this[0].log[0].resource_log_enabled == false
    error_message = "Native resource-log forwarding stays off by default (duplicate prevention)."
  }
  assert {
    condition     = length(azurerm_datadog_monitor_tag_rule.this[0].metric[0].filter) == 2
    error_message = "Metric tag filters become tag rules."
  }
  assert {
    condition     = length(azapi_resource.monitored_subscriptions) == 1 && azapi_resource.monitored_subscriptions[0].body.properties.monitoredSubscriptionList[0].subscriptionId == "bbbbbbbb-0000-0000-0000-000000000000"
    error_message = "Additional subscriptions via monitoredSubscriptions (AzAPI gap)."
  }
  assert {
    condition     = length(datadog_integration_azure.this) == 0 && output.integration_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.Datadog/monitors/dd"
    error_message = "Native monitor id is the integration id."
  }
}

run "native_existing_monitor" {
  command = plan
  variables {
    mode             = "native"
    subscription_ids = ["aaaaaaaa-0000-0000-0000-000000000000"]
    native           = { existing_monitor_id = "/subscriptions/aaaaaaaa-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Datadog/monitors/existing" }
  }
  assert {
    condition     = length(azurerm_datadog_monitor.this) == 0 && length(azapi_resource.monitored_subscriptions) == 0 && length(azurerm_datadog_monitor_tag_rule.this) == 1
    error_message = "Existing monitor: only tag rules managed."
  }
}

run "none_mode" {
  command = plan
  variables {
    mode = "none"
  }
  assert {
    condition     = output.integration_id == null && length(datadog_integration_azure.this) == 0
    error_message = "none creates nothing."
  }
}

run "reject_secret_mode_without_secret" {
  command = plan
  variables {
    client_secret = null
  }
  expect_failures = [datadog_integration_azure.this]
}

run "reject_bad_subscription" {
  command = plan
  variables {
    subscription_ids = ["not-a-guid"]
  }
  expect_failures = [var.subscription_ids]
}

# ------------------------------------------------------------------ native vs Event Hubs log forwarding
run "native_log_forwarding_alternative" {
  command = plan
  variables {
    mode             = "native"
    subscription_ids = ["aaaaaaaa-0000-0000-0000-000000000000"]
    native = {
      existing_monitor_id    = "/subscriptions/aaaaaaaa-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Datadog/monitors/existing"
      send_subscription_logs = true
      send_resource_logs     = true
      send_aad_logs          = true
      log_tag_filters        = [{ name = "datadog-logs", value = "true" }]
    }
    # the Event Hubs path covers ANOTHER subscription only -> no overlap
    eventhub_log_forwarding = { activity_log_subscription_ids = ["bbbbbbbb-0000-0000-0000-000000000000"] }
  }
  assert {
    condition     = azurerm_datadog_monitor_tag_rule.this[0].log[0].subscription_log_enabled && azurerm_datadog_monitor_tag_rule.this[0].log[0].resource_log_enabled && azurerm_datadog_monitor_tag_rule.this[0].log[0].aad_log_enabled && length(azurerm_datadog_monitor_tag_rule.this[0].log[0].filter) == 1
    error_message = "Native tag rule log block: subscription / resource / Entra logs + tag filters."
  }
  assert {
    condition     = output.native_log_forwarding.aad_logs && jsonencode(output.native_log_forwarding.subscription_log_subscription_ids) == jsonencode(["aaaaaaaa-0000-0000-0000-000000000000"])
    error_message = "native_log_forwarding summary feeds modules/azure-logs."
  }
}

run "reject_native_and_eventhub_activity_log_same_subscription" {
  command = plan
  variables {
    mode                    = "native"
    native                  = { existing_monitor_id = "/subscriptions/aaaaaaaa-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Datadog/monitors/existing" }
    eventhub_log_forwarding = { activity_log_subscription_ids = ["AAAAAAAA-0000-0000-0000-000000000000"] }
  }
  expect_failures = [var.eventhub_log_forwarding]
}

run "reject_native_resource_logs_with_diagnostic_settings" {
  command = plan
  variables {
    mode                    = "native"
    native                  = { existing_monitor_id = "/subscriptions/aaaaaaaa-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Datadog/monitors/existing", send_subscription_logs = false, send_resource_logs = true }
    eventhub_log_forwarding = { resource_log_subscription_ids = ["bbbbbbbb-0000-0000-0000-000000000000"] }
  }
  expect_failures = [var.eventhub_log_forwarding]
}

run "reject_native_and_eventhub_entra" {
  command = plan
  variables {
    mode                    = "native"
    native                  = { existing_monitor_id = "/subscriptions/aaaaaaaa-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Datadog/monitors/existing", send_subscription_logs = false, send_aad_logs = true }
    eventhub_log_forwarding = { entra_enabled = true }
  }
  expect_failures = [var.eventhub_log_forwarding]
}

run "app_registration_ignores_eventhub_paths" {
  command = plan
  variables {
    eventhub_log_forwarding = { activity_log_subscription_ids = ["aaaaaaaa-0000-0000-0000-000000000000"], entra_enabled = true }
  }
  assert {
    condition     = length(datadog_integration_azure.this) == 1 && length(output.native_log_forwarding.subscription_log_subscription_ids) == 0
    error_message = "app_registration mode forwards no logs, so the Event Hubs path is the only one."
  }
}
