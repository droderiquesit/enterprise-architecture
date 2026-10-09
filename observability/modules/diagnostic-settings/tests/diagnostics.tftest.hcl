mock_provider "azurerm" {
  override_during = plan

  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["inventory_web"]
    values = {
      log_category_types = ["AppServiceConsoleLogs", "AppServiceAppLogs", "AppServiceHTTPLogs", "AppServicePlatformLogs", "AppServiceAuditLogs"]
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["durable_func"]
    values = {
      log_category_types = ["FunctionAppLogs"]
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["aca_env"]
    values = {
      log_category_types = ["ContainerAppConsoleLogs", "ContainerAppSystemLogs", "AppEnvSpringAppConsoleLogs"]
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["orders_db"]
    values = {
      log_category_types = ["SQLInsights", "Errors", "Deadlocks", "SQLSecurityAuditEvents"]
    }
  }
}

variables {
  destination = {
    authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
    app_logs_hub          = "app-logs"
    platform_logs_hub     = "platform-logs"
    location              = "swedencentral"
  }
  resources = {
    inventory_web = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/app-inventory"
      app_log_route = "eventhub"
      location      = "swedencentral"
    }
    durable_func = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/func-durable"
      app_log_route = "eventhub"
    }
    aca_env = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/cae"
      app_log_route = "sidecar"
    }
    orders_db = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Sql/servers/sql1/databases/orders"
    }
    vnet = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
    }
  }
}


run "routes_and_categories" {
  command = plan

  assert {
    condition     = output.resource_types["orders_db"] == "microsoft.sql/servers/databases" && output.resource_types["aca_env"] == "microsoft.app/managedenvironments"
    error_message = "Resource types (incl. child types) must be derived from ids."
  }
  assert {
    condition     = jsonencode(output.app_log_settings["inventory_web"]) == jsonencode(["AppServiceAppLogs", "AppServiceConsoleLogs"]) && jsonencode(output.app_log_settings["durable_func"]) == jsonencode(["FunctionAppLogs"])
    error_message = "Event Hub route exports only supported app-log categories."
  }
  assert {
    condition     = !contains(keys(output.app_log_settings), "aca_env") && jsonencode(output.platform_log_settings["aca_env"]) == jsonencode(["ContainerAppSystemLogs"])
    error_message = "Sidecar route must NOT export ContainerAppConsoleLogs (duplicate prevention); system logs still go to platform hub."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["inventory_web"]) == jsonencode(["AppServiceAuditLogs", "AppServiceHTTPLogs", "AppServicePlatformLogs"])
    error_message = "Platform allow-list intersected with supported categories."
  }
  assert {
    condition     = !contains(keys(output.platform_log_settings), "durable_func")
    error_message = "No setting when no platform category is supported."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["orders_db"]) == jsonencode(["Deadlocks", "Errors", "SQLSecurityAuditEvents"])
    error_message = "SQL database platform categories."
  }
  assert {
    condition     = jsonencode(output.unsupported_resources) == jsonencode(["vnet"]) && !contains(keys(azurerm_monitor_diagnostic_setting.platform_logs), "vnet")
    error_message = "Unknown types are skipped without a data lookup."
  }
  assert {
    condition     = azurerm_monitor_diagnostic_setting.app_logs["inventory_web"].name == "datadog-obs-app-logs" && azurerm_monitor_diagnostic_setting.app_logs["inventory_web"].eventhub_name == "app-logs"
    error_message = "Deterministic names and the app hub."
  }
  assert {
    condition     = azurerm_monitor_diagnostic_setting.platform_logs["orders_db"].eventhub_name == "platform-logs" && length(azurerm_monitor_diagnostic_setting.platform_logs["orders_db"].enabled_metric) == 0
    error_message = "Platform hub; metrics never exported via diagnostic settings."
  }
}

run "daemonset_route_excludes_app_logs" {
  command = plan
  variables {
    resources = {
      inventory_web = {
        id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/app-inventory"
        app_log_route = "sidecar"
      }
    }
  }
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.app_logs) == 0 && jsonencode(output.excluded_app_log_resources) == jsonencode(["inventory_web"])
    error_message = "Non-eventhub routes never export app logs."
  }
}

run "reject_bad_route" {
  command = plan
  variables {
    resources = {
      x = {
        id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/app"
        app_log_route = "stdout"
      }
    }
  }
  expect_failures = [var.resources]
}

run "reject_region_mismatch" {
  command = plan
  variables {
    resources = {
      inventory_web = {
        id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/app-inventory"
        app_log_route = "eventhub"
        location      = "westeurope"
      }
    }
  }
  expect_failures = [azurerm_monitor_diagnostic_setting.app_logs["inventory_web"], azurerm_monitor_diagnostic_setting.platform_logs["inventory_web"]]
}

run "reject_hub_level_rule" {
  command = plan
  variables {
    destination = {
      authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/eventhubs/app-logs/authorizationRules/x"
      app_logs_hub          = "app-logs"
      platform_logs_hub     = "platform-logs"
    }
  }
  expect_failures = [var.destination]
}

# ---------------------------------------------------------------------------------------- tier policy
run "tiers_are_cumulative_and_supersede" {
  command = plan
  variables {
    platform_log_tier = "security"
    resources = {
      aks = {
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks1"
      }
      aks_std = {
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks2"
        tier = "standard"
      }
      aks_verbose = {
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks3"
        tier = "verbose"
      }
      kv = {
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv1"
      }
      blob = {
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-st/providers/Microsoft.Storage/storageAccounts/st1/blobServices/default"
        tier = "verbose"
      }
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["aks"]
    values = { log_category_types = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "cloud-controller-manager", "guard", "csi-azuredisk-controller"] }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["aks_std"]
    values = { log_category_types = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "cloud-controller-manager", "guard", "csi-azuredisk-controller"] }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["aks_verbose"]
    values = { log_category_types = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "cloud-controller-manager", "guard", "csi-azuredisk-controller"] }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["kv"]
    values = { log_category_types = ["AuditEvent", "AzurePolicyEvaluationDetails"] }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["blob"]
    values = { log_category_types = ["StorageRead", "StorageWrite", "StorageDelete"] }
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["aks"]) == jsonencode(["guard", "kube-audit-admin"])
    error_message = "security tier: AKS audit essentials only (no full kube-audit)."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["aks_std"]) == jsonencode(["cluster-autoscaler", "guard", "kube-apiserver", "kube-audit-admin"])
    error_message = "standard tier: + kube-apiserver and cluster-autoscaler."
  }
  assert {
    condition     = contains(output.platform_log_settings["aks_verbose"], "kube-audit") && !contains(output.platform_log_settings["aks_verbose"], "kube-audit-admin")
    error_message = "verbose tier: full kube-audit supersedes kube-audit-admin (no duplicate audit events)."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["kv"]) == jsonencode(["AuditEvent"]) && output.platform_log_tiers["aks_std"] == "standard" && output.platform_log_tiers["kv"] == "security"
    error_message = "Key Vault AuditEvent at security tier; per-resource tier override wins."
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["blob"]) == jsonencode(["StorageDelete", "StorageRead", "StorageWrite"])
    error_message = "Storage read/write/delete at verbose tier."
  }
}

run "overrides_and_legacy_allowlist" {
  command = plan
  variables {
    platform_log_allowlist_overrides = { "microsoft.keyvault/vaults" = ["AzurePolicyEvaluationDetails"] }
    resources = {
      kv = {
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv1"
      }
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["kv"]
    values = { log_category_types = ["AuditEvent", "AzurePolicyEvaluationDetails"] }
  }
  assert {
    condition     = jsonencode(output.platform_log_settings["kv"]) == jsonencode(["AzurePolicyEvaluationDetails"])
    error_message = "A type override replaces the tier list for that type."
  }
}

run "legacy_allowlist_replaces_policy" {
  command = plan
  variables {
    platform_log_allowlist = { "microsoft.keyvault/vaults" = [] }
    resources = {
      kv = {
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv1"
      }
    }
  }
  override_data {
    target = data.azurerm_monitor_diagnostic_categories.this["kv"]
    values = { log_category_types = ["AuditEvent"] }
  }
  assert {
    condition     = length(output.platform_log_settings) == 0
    error_message = "A legacy allow-list (1.0.x input) replaces the policy entirely."
  }
}

run "destination_namespace_is_never_a_source" {
  command = plan
  variables {
    resources = {
      obs_hub = {
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns"
      }
    }
  }
  assert {
    condition     = jsonencode(output.self_referencing_resources) == jsonencode(["obs_hub"]) && length(azurerm_monitor_diagnostic_setting.platform_logs) == 0 && length(output.unsupported_resources) == 0
    error_message = "The destination namespace must not stream its own logs into itself."
  }
}

run "reject_unknown_tier" {
  command = plan
  variables {
    platform_log_tier = "everything"
  }
  expect_failures = [var.platform_log_tier]
}
