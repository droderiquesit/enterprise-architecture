mock_provider "azurerm" {}

variables {
  destination = {
    authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
    eventhub_name         = "activity-logs"
  }
  activity_log = {
    subscription_ids = ["00000000-0000-0000-0000-000000000000", "11111111-1111-1111-1111-111111111111"]
  }
}

run "activity_log_per_subscription_all_categories" {
  command = plan
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.activity_log) == 2 && azurerm_monitor_diagnostic_setting.activity_log["11111111-1111-1111-1111-111111111111"].target_resource_id == "/subscriptions/11111111-1111-1111-1111-111111111111"
    error_message = "One subscription-scoped setting per subscription."
  }
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.activity_log["00000000-0000-0000-0000-000000000000"].enabled_log) == 8 && azurerm_monitor_diagnostic_setting.activity_log["00000000-0000-0000-0000-000000000000"].eventhub_name == "activity-logs"
    error_message = "All 8 Activity Log categories to the activity-logs hub by default."
  }
  assert {
    condition     = azurerm_monitor_diagnostic_setting.activity_log["00000000-0000-0000-0000-000000000000"].name == "datadog-obs-activity-logs" && length(azurerm_monitor_aad_diagnostic_setting.entra) == 0
    error_message = "Deterministic name; Entra off by default."
  }
  assert {
    condition     = output.log_forwarding.entra_enabled == false && length(output.log_forwarding.activity_log_subscription_ids) == 2
    error_message = "log_forwarding summary."
  }
}

run "category_subset_and_disable" {
  command = plan
  variables {
    activity_log = {
      enabled          = false
      subscription_ids = ["00000000-0000-0000-0000-000000000000"]
      categories       = ["Administrative", "Policy"]
    }
  }
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.activity_log) == 0 && length(output.activity_log_categories) == 0
    error_message = "enabled = false removes only the diagnostic settings."
  }
}

run "entra_enabled_with_acknowledgement" {
  command = plan
  variables {
    entra = {
      enabled                   = true
      acknowledge_prerequisites = true
      categories                = ["AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs"]
    }
  }
  assert {
    condition     = length(azurerm_monitor_aad_diagnostic_setting.entra) == 1 && azurerm_monitor_aad_diagnostic_setting.entra[0].eventhub_name == "activity-logs" && length(azurerm_monitor_aad_diagnostic_setting.entra[0].enabled_log) == 3
    error_message = "Entra setting to the control-plane hub with the selected categories."
  }
}

run "reject_entra_without_acknowledgement" {
  command = plan
  variables {
    entra = { enabled = true }
  }
  expect_failures = [var.entra]
}

run "reject_unknown_entra_category" {
  command = plan
  variables {
    entra = { enabled = true, acknowledge_prerequisites = true, categories = ["SignInLog"] }
  }
  expect_failures = [var.entra]
}

run "reject_unknown_activity_category" {
  command = plan
  variables {
    activity_log = { subscription_ids = ["00000000-0000-0000-0000-000000000000"], categories = ["Write"] }
  }
  expect_failures = [var.activity_log]
}

run "reject_resource_id_instead_of_guid" {
  command = plan
  variables {
    activity_log = { subscription_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000"] }
  }
  expect_failures = [var.activity_log]
}

run "reject_duplicate_with_native_subscription_logs" {
  command = plan
  variables {
    native_log_forwarding = { subscription_log_subscription_ids = ["11111111-1111-1111-1111-111111111111"] }
  }
  expect_failures = [azurerm_monitor_diagnostic_setting.activity_log["11111111-1111-1111-1111-111111111111"], azurerm_monitor_diagnostic_setting.activity_log["00000000-0000-0000-0000-000000000000"]]
}

run "reject_entra_duplicate_with_native_aad_logs" {
  command = plan
  variables {
    entra                 = { enabled = true, acknowledge_prerequisites = true }
    native_log_forwarding = { aad_logs = true }
  }
  expect_failures = [azurerm_monitor_aad_diagnostic_setting.entra[0]]
}
