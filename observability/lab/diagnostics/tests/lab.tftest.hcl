mock_provider "azurerm" {
  override_during = plan
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["deploy-appservice.inventory"]
    values = { log_category_types = ["AppServiceConsoleLogs", "AppServiceAppLogs", "AppServiceHTTPLogs"] }
  }
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["platform-containerapps.environment"]
    values = { log_category_types = ["ContainerAppConsoleLogs", "ContainerAppSystemLogs"] }
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
  obs_telemetry_transport = {
    event_hub = {
      authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
      app_logs_hub          = "app-logs"
      platform_logs_hub     = "platform-logs"
      location              = "swedencentral"
    }
  }
  resources = {
    "deploy-appservice.inventory" = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/eh-app-inventory-dev-sec"
      app_log_route = "eventhub"
      location      = "swedencentral"
    }
    "platform-containerapps.environment" = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-apps-dev-sec"
      app_log_route = "sidecar"
      location      = "swedencentral"
    }
  }
}

run "lab_assembly" {
  command = plan
  assert {
    condition     = jsonencode(output.app_log_settings["deploy-appservice.inventory"]) == jsonencode(["AppServiceAppLogs", "AppServiceConsoleLogs"])
    error_message = "App Service console/app logs go to the app-logs hub."
  }
  assert {
    condition     = !contains(keys(output.app_log_settings), "platform-containerapps.environment") && contains(output.excluded_app_log_resources, "platform-containerapps.environment")
    error_message = "ACA console logs are collected by sidecars, never exported."
  }
}

run "empty_resources_is_a_noop" {
  command = plan
  variables {
    resources = {}
  }
  assert {
    condition     = length(output.app_log_settings) == 0 && length(output.platform_log_settings) == 0
    error_message = "No resources, no settings."
  }
}

run "reject_unknown_route" {
  command = plan
  variables {
    resources = {
      x = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Web/sites/x", app_log_route = "otlp" }
    }
  }
  expect_failures = [var.resources]
}
