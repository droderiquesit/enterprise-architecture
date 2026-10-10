variables {
  env = "dev"
  resources = {
    orders-app = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-orders", type = "Microsoft.App/containerApps", tags = { env = "dev", service = "hello-orders-api", team = "orders", version = "1" } }
    inventory  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Web/sites/app-inv", type = "Microsoft.Web/sites", tags = { env = "dev", service = "hello-inventory-api", team = "orders" } }
    orders-db  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Sql/servers/sql/databases/orders", type = "Microsoft.Sql/servers/databases", tags = { env = "dev", service = "hello-orders-api" } }
    aks        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks", type = "Microsoft.ContainerService/managedClusters" }
    worker-vm  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm", type = "Microsoft.Compute/virtualMachines" }
    inv-win    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vmw", type = "Microsoft.Compute/virtualMachines", os_type = "windows" }
    frontend   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Web/staticSites/swa", type = "Microsoft.Web/staticSites" }
  }
}

run "one_collector_per_signal" {
  command = plan
  assert {
    condition     = output.plan["orders-app"].app_logs == "fluent_bit_sidecar" && output.plan["orders-app"].apm == "agent_gateway" && output.plan["orders-app"].log_destination == "observability_pipelines"
    error_message = "Container App: Fluent Bit sidecar -> OP, Datadog tracer -> APM gateway"
  }
  assert {
    condition     = output.plan["inventory"].app_logs == "eventhub" && output.plan["inventory"].platform_logs == "diagnostic_settings" && output.diagnostic_targets["inventory"].app_log_route == "eventhub"
    error_message = "App Service: diagnostic settings (app + platform categories) -> Event Hubs"
  }
  assert {
    condition     = output.plan["orders-db"].dbm && contains(keys(output.dbm_candidates), "orders-db") && output.plan["orders-db"].metrics == "azure_integration"
    error_message = "SQL database: integration metrics + DBM candidate"
  }
  assert {
    condition     = output.plan["aks"].agent == "datadog_agent_helm" && output.plan["aks"].app_logs == "datadog_agent" && output.plan["aks"].apm == "ssi_kubernetes"
    error_message = "AKS: Agent (Helm) collects logs, SSI for APM"
  }
  assert {
    condition     = output.plan["worker-vm"].apm == "ssi_host" && output.plan["worker-vm"].app_logs == "datadog_agent" && output.plan["inv-win"].apm == "otel" && output.plan["inv-win"].app_logs == "fluent_bit_host"
    error_message = "Linux VM: Agent + host SSI; Windows VM: Fluent Bit + OTel"
  }
  assert {
    condition     = output.plan["frontend"].apm == "rum" && !contains(keys(output.diagnostic_targets), "frontend")
    error_message = "Static Web App: RUM; no diagnostic categories"
  }
  assert {
    condition     = output.scope_tags["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg/providers/microsoft.app/containerapps/ca-orders"]["team"] == "orders" && !contains(keys(output.scope_tags["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg/providers/microsoft.app/containerapps/ca-orders"]), "version")
    error_message = "resource-scope tags for the log pipeline (lowercase ids, no version)"
  }
}

run "fluent_bit_direct_policy" {
  command = plan
  variables {
    fleet_policy = { apiVersion = "observability/fleet-policy/v1", kind = "FleetPolicy", log_pipeline = "fluent_bit_direct", apm = { mode = "otel" } }
  }
  assert {
    condition     = output.plan["aks"].app_logs == "fluent_bit_daemonset" && output.plan["aks"].apm == "otel" && output.plan["worker-vm"].log_destination == "datadog_intake"
    error_message = "2.x path"
  }
}
