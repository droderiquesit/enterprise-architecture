# Fleet inventory (pure function): one list of resources -> the collection plan of each, per signal, from the fleet
# policy and the Datadog support matrix (docs/guides/datadog-fleet-collection.md of the source repository). The plan
# feeds the collection modules (diagnostic-settings targets, host-agents hosts, dbm candidates, Observability Pipelines
# / aggregator resource-scope tags) so every resource type gets exactly one authoritative collector per signal.
module "fleet" {
  source = "../fleet-policy"
  policy = var.fleet_policy
  env    = var.env
}

locals {
  op_mode = module.fleet.log_pipeline == "observability_pipelines"
  agent_n = module.fleet.node_collector == "agent"
  apm_dd  = try(module.fleet.sections.apm.mode, "datadog")

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

  plan = { for k, r in var.resources : k => merge(
    {
      id   = r.id
      type = lower(r.type)
      kind = lookup(local.kind_by_type, lower(r.type), "paas")
    },
    {
      # Azure Monitor metrics + resource metadata/tags: the Datadog Azure integration, for every resource type
      metrics = "azure_integration"
      # platform (non-application) resource logs: diagnostic settings -> Event Hubs -> log pipeline
      platform_logs = contains(local.policy_types, lower(r.type)) ? "diagnostic_settings" : "none"
      app_logs = coalesce(r.app_log_route, lookup({
        host                       = local.agent_n && r.os_type == "linux" ? "datadog_agent" : "fluent_bit_host"
        kubernetes                 = local.agent_n ? "datadog_agent" : "fluent_bit_daemonset"
        container_app              = "fluent_bit_sidecar"
        container_instance         = "fluent_bit_sidecar"
        app_service                = "eventhub"
        logic_app                  = "eventhub"
        container_apps_environment = "eventhub_console_allow_list"
        batch                      = "fluent_bit_host"
      }, lookup(local.kind_by_type, lower(r.type), "paas"), "none"))
      log_destination = local.op_mode ? "observability_pipelines" : "datadog_intake"
      agent = lookup({
        host       = "datadog_agent_installer"
        kubernetes = "datadog_agent_helm"
      }, lookup(local.kind_by_type, lower(r.type), "paas"), "none")
      apm = local.apm_dd != "datadog" ? local.apm_dd : lookup({
        host               = r.os_type == "linux" ? "ssi_host" : "otel"
        kubernetes         = "ssi_kubernetes"
        container_app      = try(module.fleet.sections.apm.managed_runtime_path, "agent_gateway")
        container_instance = "agent_gateway"
        app_service        = "agent_gateway"
        static_web_app     = "rum"
      }, lookup(local.kind_by_type, lower(r.type), "paas"), "none")
      dbm = contains(local.dbm_types, lower(r.type))
      # resource-scope tags for the log pipeline (platform logs of this resource carry its owner's tags)
      scope_tags = { for tk, tv in r.tags : tk => tv if !contains(["version"], tk) }
    },
  ) }
}
