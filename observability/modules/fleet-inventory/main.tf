# Fleet inventory (pure function): one list of resources -> the collection plan of each, per signal, from the fleet
# policy and the Datadog support matrix (docs/guides/datadog-fleet-collection.md of the source repository). The plan
# feeds the collection modules (diagnostic-settings targets, host-agents hosts, dbm candidates, Observability Pipelines
# / aggregator resource-scope tags) so every resource type gets exactly one authoritative collector per signal.
module "fleet" {
  source = "../fleet-policy"
  policy = var.fleet_policy
  env    = var.env
}

# Per-resource decision of the fleet policy (log collector, APM method) for resources that host workloads, so the plan
# follows the same per-architecture defaults and overrides as modules/instrumentation and the Agent modules. A missing
# runtime is resolved as a tracer runtime (dotnet): the plan shows the path a workload on the resource would take.
module "fleet_resource" {
  source       = "../fleet-policy"
  for_each     = { for k, r in local.resource : k => r if r.arch != null }
  policy       = var.fleet_policy
  env          = var.env
  architecture = each.value.arch
  runtime      = coalesce(var.resources[each.key].runtime, "dotnet")
  os_type      = var.resources[each.key].os_type
}

locals {
  op_mode = module.fleet.log_pipeline == "observability_pipelines"

  policy_types = keys(jsondecode(file("${path.module}/../diagnostic-settings/category-policy.json")).types)

  kind_by_type = {
    "microsoft.compute/virtualmachines"              = "host"
    "microsoft.compute/virtualmachinescalesets"      = "host"
    "microsoft.containerservice/managedclusters"     = "kubernetes"
    "microsoft.redhatopenshift/openshiftclusters"    = "kubernetes"
    "microsoft.app/containerapps"                    = "container_app"
    "microsoft.app/jobs"                             = "container_app"
    "microsoft.app/managedenvironments"              = "container_apps_environment"
    "microsoft.containerinstance/containergroups"    = "container_instance"
    "microsoft.web/sites"                            = "app_service"
    "microsoft.web/sites/slots"                      = "app_service"
    "microsoft.logic/workflows"                      = "logic_app"
    "microsoft.web/staticsites"                      = "static_web_app"
    "microsoft.sql/servers/databases"                = "database"
    "microsoft.sql/managedinstances"                 = "database"
    "microsoft.dbforpostgresql/flexibleservers"      = "database"
    "microsoft.dbformysql/flexibleservers"           = "database"
    "microsoft.sqlvirtualmachine/sqlvirtualmachines" = "database"
    "microsoft.batch/batchaccounts"                  = "batch"
  }
  dbm_types = ["microsoft.sql/servers/databases", "microsoft.sql/managedinstances", "microsoft.dbforpostgresql/flexibleservers", "microsoft.dbformysql/flexibleservers", "microsoft.sqlvirtualmachine/sqlvirtualmachines"]
  # fleet-policy architecture of each kind (resources[*].architecture wins, e.g. functions on Microsoft.Web/sites)
  arch_by_kind = {
    kubernetes         = "aks"
    container_app      = "aca"
    container_instance = "aci"
    app_service        = "appservice"
    logic_app          = "logicapp"
    batch              = "batch"
  }
  resource = { for k, r in var.resources : k => {
    kind = lookup(local.kind_by_type, lower(r.type), "paas")
    arch = r.architecture != null ? r.architecture : (
      lower(r.type) == "microsoft.compute/virtualmachinescalesets" ? "vmss" :
      lower(r.type) == "microsoft.compute/virtualmachines" ? "vm" :
      lookup(local.arch_by_kind, lookup(local.kind_by_type, lower(r.type), "paas"), null)
    )
  } }

  # fleet-policy log_collector -> plan value (kubernetes / hosts keep their 3.x names)
  app_log_value = {
    agent              = "datadog_agent"
    agent_sidecar      = "datadog_agent_sidecar"
    serverless_init    = "serverless_init"
    azure              = "eventhub"
    fluent_bit_sidecar = "fluent_bit_sidecar"
    none               = "none"
  }
  app_logs = { for k, r in local.resource : k => (
    r.kind == "container_apps_environment" ? "eventhub_console_allow_list" :
    !contains(keys(module.fleet_resource), k) ? "none" :
    module.fleet_resource[k].log_collector == "fluent_bit" ? (r.kind == "kubernetes" ? "fluent_bit_daemonset" : "fluent_bit_host") :
    lookup(local.app_log_value, module.fleet_resource[k].log_collector, "none")
  ) }
  apm = { for k, r in local.resource : k => (
    r.kind == "static_web_app" ? "rum" :
    !contains(["host", "kubernetes", "container_app", "container_instance", "app_service"], r.kind) || !contains(keys(module.fleet_resource), k) ? "none" :
    module.fleet_resource[k].apm.mode == "datadog" ? module.fleet_resource[k].apm.method : module.fleet_resource[k].apm.mode
  ) }
  agent = { for k, r in local.resource : k => (
    r.kind == "host" ? "datadog_agent_vm_application" :
    r.kind == "kubernetes" ? "datadog_agent_helm" :
    local.app_logs[k] == "datadog_agent_sidecar" || local.apm[k] == "agent_sidecar" ? "datadog_agent_sidecar" :
    local.app_logs[k] == "serverless_init" || local.apm[k] == "serverless_init" ? "serverless_init" : "none"
  ) }

  plan = { for k, r in var.resources : k => {
    id   = r.id
    type = lower(r.type)
    kind = local.resource[k].kind
    # Azure Monitor metrics + resource metadata/tags: the Datadog Azure integration, for every resource type
    metrics = "azure_integration"
    # platform (non-application) resource logs: diagnostic settings -> Event Hubs -> log pipeline
    platform_logs   = contains(local.policy_types, lower(r.type)) ? "diagnostic_settings" : "none"
    app_logs        = coalesce(r.app_log_route, local.app_logs[k])
    log_destination = (contains(keys(module.fleet_resource), k) ? module.fleet_resource[k].log_pipeline == "observability_pipelines" : local.op_mode) ? "observability_pipelines" : "datadog_intake"
    agent           = local.agent[k]
    apm             = local.apm[k]
    dbm             = contains(local.dbm_types, lower(r.type))
    # resource-scope tags for the log pipeline (platform logs of this resource carry its owner's tags)
    scope_tags = { for tk, tv in r.tags : tk => tv if !contains(["version"], tk) }
  } }
}
