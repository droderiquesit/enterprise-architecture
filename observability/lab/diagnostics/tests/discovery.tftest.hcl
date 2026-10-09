# Contract-driven discovery (discovered_contracts from tools/contracts/materialize.py).
mock_provider "azurerm" {
  override_during = plan
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["aca-environment.0"]
    values = { log_category_types = ["ContainerAppConsoleLogs", "ContainerAppSystemLogs"] }
  }
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["deploy-appservice.apps.hello-inventory-api"]
    values = { log_category_types = ["AppServiceConsoleLogs", "AppServiceAppLogs", "AppServiceHTTPLogs"] }
  }
  override_data {
    target = module.diagnostics.data.azurerm_monitor_diagnostic_categories.this["platform-db-sql.databases.orders"]
    values = { log_category_types = ["Errors", "Deadlocks", "SQLSecurityAuditEvents"] }
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
    fluentbit = { aca_console_allow = ["eh-caj-*"] }
    event_hub = {
      authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
      app_logs_hub          = "app-logs"
      platform_logs_hub     = "platform-logs"
    }
  }
  discovered_contracts = {
    "platform-containerapps" = {
      environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-apps-dev-sec"
    }
    "platform-aks" = {
      cluster_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec"
    }
    "platform-db-sql" = {
      server    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Sql/servers/eh-sql-dev" }
      databases = { orders = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Sql/servers/eh-sql-dev/databases/orders", name = "orders" } }
    }
    "deploy-core-aca" = {
      environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-apps-dev-sec"
      apps = {
        "hello-bff" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.App/containerApps/eh-ca-bff-dev", name = "eh-ca-bff-dev", type = "Microsoft.App/containerApps", app_log_route = "sidecar" }
      }
    }
    "deploy-jobs" = {
      apps = {
        "hello-jobs-reconcile" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-jobs/providers/Microsoft.App/jobs/eh-caj-reconcile-dev", name = "eh-caj-reconcile-dev", type = "Microsoft.App/jobs", app_log_route = "eventhub" }
      }
    }
    "deploy-appservice" = {
      apps = {
        "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Web/sites/eh-app-inventory-dev", name = "eh-app-inventory-dev", type = "Microsoft.Web/sites", app_log_route = "eventhub" }
      }
    }
    "deploy-core-aks" = {
      apps = {
        "hello-bff" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec/namespaces/hello/deployments/hello-bff", name = "hello-bff", type = "Kubernetes/Deployment", app_log_route = "daemonset" }
      }
    }
  }
}

run "jobs_route_environment_console_logs_to_app_hub" {
  command = plan
  assert {
    condition     = output.discovered_targets["aca-environment.0"].app_log_route == "eventhub"
    error_message = "A job with app_log_route=eventhub makes the environment export ContainerAppConsoleLogs."
  }
  assert {
    condition     = jsonencode(output.app_log_settings["aca-environment.0"]) == jsonencode(["ContainerAppConsoleLogs"]) && jsonencode(output.platform_log_settings["aca-environment.0"]) == jsonencode(["ContainerAppSystemLogs"])
    error_message = "Console logs -> app-logs hub, system logs -> platform-logs hub."
  }
  assert {
    condition     = jsonencode(output.aca_eventhub_apps) == jsonencode(["eh-caj-reconcile-dev"])
    error_message = "Only the job travels via Event Hubs (the sidecar app is filtered by the aggregator allow-list)."
  }
  assert {
    condition     = output.discovered_targets["deploy-appservice.apps.hello-inventory-api"].app_log_route == "eventhub" && !contains(keys(output.discovered_targets), "deploy-core-aks.apps.hello-bff") && !contains(keys(output.discovered_targets), "deploy-core-aca.apps.hello-bff")
    error_message = "Web apps are targets; AKS deployments and individual container apps are not."
  }
  assert {
    condition     = contains(keys(output.discovered_targets), "platform-aks.cluster") && jsonencode(output.platform_log_settings["platform-db-sql.databases.orders"]) == jsonencode(["Deadlocks", "Errors", "SQLSecurityAuditEvents"])
    error_message = "Platform resources from the explicit extraction map."
  }
}

run "sidecar_only_environment_exports_no_console_logs" {
  command = plan
  variables {
    discovered_contracts = {
      "platform-containerapps" = {
        environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-apps-dev-sec"
      }
      "deploy-core-aca" = {
        apps = {
          "hello-bff" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.App/containerApps/eh-ca-bff-dev", name = "eh-ca-bff-dev", type = "Microsoft.App/containerApps", app_log_route = "sidecar" }
        }
      }
    }
  }
  assert {
    condition     = output.discovered_targets["aca-environment.0"].app_log_route == "sidecar" && !contains(keys(output.app_log_settings), "aca-environment.0")
    error_message = "No eventhub app in the environment -> no ContainerAppConsoleLogs export."
  }
}

run "allow_list_mismatch_is_flagged" {
  command = plan
  variables {
    obs_telemetry_transport = {
      fluentbit = { aca_console_allow = ["eh-ca-other-*"] }
      event_hub = {
        authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs/providers/Microsoft.EventHub/namespaces/evhns/authorizationRules/diagnostic-settings-send"
        app_logs_hub          = "app-logs"
        platform_logs_hub     = "platform-logs"
      }
    }
  }
  expect_failures = [check.aca_console_allow_covers_eventhub_apps]
}
