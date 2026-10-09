# Activity Log / Entra / SQL master audit / tier wiring of the lab root.
mock_provider "azurerm" {
  override_during = plan
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["platform-db-sql.master"]
    values = { log_category_types = ["SQLSecurityAuditEvents", "DevOpsOperationsAudit", "Errors"] }
  }
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["platform-aks.cluster"]
    values = { log_category_types = ["kube-apiserver", "kube-audit", "kube-audit-admin", "guard", "cluster-autoscaler"] }
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
      activity_logs_hub     = "activity-logs"
    }
  }
  discovered_contracts = {
    "platform-aks" = {
      cluster_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev"
    }
    "platform-db-sql" = {
      server    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Sql/servers/eh-sql-dev" }
      databases = {}
    }
  }
}

run "activity_log_on_by_default_to_activity_hub" {
  command = plan
  assert {
    condition     = length(module.azure_logs.activity_log_settings) == 1 && output.control_plane_log_forwarding.destination_hub == "activity-logs" && output.entra_setting_id == null
    error_message = "Lab default: Activity Log of the environment subscription to the activity-logs hub; Entra off."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["platform-db-sql.master"]) == jsonencode(["DevOpsOperationsAudit", "SQLSecurityAuditEvents"])
    error_message = "Server-level SQL audit via the master database diagnostic setting."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["platform-aks.cluster"]) == jsonencode(["cluster-autoscaler", "guard", "kube-apiserver", "kube-audit-admin"]) && output.platform_log_tiers["platform-aks.cluster"] == "standard"
    error_message = "Standard tier by default (kube-audit-admin + guard + kube-apiserver, never full kube-audit)."
  }
}

run "minimal_profile_security_tier_and_shared_hub" {
  command = plan
  variables {
    settings = {
      platform_log_tier = "security"
      sql_server_audit  = false
      activity_log      = { extra_subscription_ids = ["11111111-1111-1111-1111-111111111111"], categories = ["Administrative", "Policy", "ServiceHealth"] }
    }
    obs_telemetry_transport = {
      event_hub = {
        authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
        app_logs_hub          = "app-logs"
        platform_logs_hub     = "platform-logs"
      }
    }
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["platform-aks.cluster"]) == jsonencode(["guard", "kube-audit-admin"]) && !contains(keys(output.discovered_targets), "platform-db-sql.master")
    error_message = "security tier; SQL master target only when sql_server_audit."
  }
  assert {
    condition     = length(module.azure_logs.activity_log_settings) == 2 && output.control_plane_log_forwarding.destination_hub == "platform-logs"
    error_message = "Extra subscriptions; 1.0.x transport contract without activity_logs_hub falls back to the platform hub."
  }
}

run "activity_log_disabled" {
  command = plan
  variables {
    settings = { activity_log = { enabled = false } }
  }
  assert {
    condition     = length(module.azure_logs.activity_log_settings) == 0
    error_message = "Disabling removes only the subscription diagnostic setting."
  }
}

run "reject_entra_without_acknowledgement" {
  command = plan
  variables {
    settings = { entra = { enabled = true } }
  }
  expect_failures = [var.settings]
}

run "reject_native_resource_logs" {
  command = plan
  variables {
    settings = { native_log_forwarding = { resource_logs = true } }
  }
  expect_failures = [var.settings]
}

run "reject_native_and_eventhub_activity_log_on_same_subscription" {
  command = plan
  variables {
    settings = { native_log_forwarding = { subscription_logs = true } }
  }
  expect_failures = [var.settings]
}
