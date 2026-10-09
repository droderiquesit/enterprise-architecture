# Explicit extraction map: which contract paths yield diagnostic-setting targets (README "Resource discovery").
#
#  deploy-*  .apps.<k>  {id, type, app_log_route, name}
#     microsoft.web/sites[/slots], microsoft.logic/workflows -> target itself, route as published
#     microsoft.app/containerapps, microsoft.app/jobs         -> folded into their Container Apps ENVIRONMENT
#                                                                (console logs are exported per environment)
#     everything else (Kubernetes/Deployment, VMs, ACI, SWA)  -> no diagnostic setting (other collectors)
#  platform-containerapps .environment_id                  -> route eventhub if any app/job in it uses eventhub,
#                                                             else sidecar (platform categories only)
#  platform-aks .cluster_id | platform-messaging .namespace_id | platform-shared .acr_id
#  platform-db-postgresql/.mysql/.sqlmi .server.id | platform-db-sql .databases.<k>.id
#  platform-db-cosmos-{nosql,mongo,cassandra,gremlin,table} .account.id | platform-db-redis .cache.id
#  platform-batch .account_id                              -> platform categories only (route none)
#  platform-db-sql .server.id + /databases/master          -> server-level SQL audit (SQLSecurityAuditEvents)
locals {
  dc = var.discovered_contracts

  app_types = ["microsoft.web/sites", "microsoft.web/sites/slots", "microsoft.logic/workflows"]
  aca_types = ["microsoft.app/containerapps", "microsoft.app/jobs"]

  deploy_apps = merge([
    for cname, c in local.dc : {
      for k, a in try(c.apps, {}) : "${cname}.apps.${k}" => {
        id            = a.id
        name          = try(a.name, k)
        type          = lower(try(a.type, ""))
        app_log_route = try(a.app_log_route, "none")
        environment   = try(c.environment_id, try(local.dc["platform-containerapps"].environment_id, null))
      } if can(a.id) && startswith(try(a.id, ""), "/subscriptions/")
    } if startswith(cname, "deploy-")
  ]...)

  deploy_targets = {
    for k, a in local.deploy_apps : k => { id = a.id, app_log_route = a.app_log_route, platform_logs = true, location = null, platform_categories = null, tier = null }
    if contains(local.app_types, a.type)
  }

  aca_apps          = { for k, a in local.deploy_apps : k => a if contains(local.aca_types, a.type) }
  aca_eventhub_apps = sort([for a in values(local.aca_apps) : a.name if a.app_log_route == "eventhub"])
  aca_env_ids = distinct(compact(concat(
    [try(local.dc["platform-containerapps"].environment_id, null)],
    [for a in values(local.aca_apps) : a.environment],
  )))
  aca_env_targets = {
    for i, env in local.aca_env_ids : "aca-environment.${i}" => {
      id                  = env
      app_log_route       = anytrue([for a in values(local.aca_apps) : a.app_log_route == "eventhub" && lower(coalesce(a.environment, "")) == lower(env)]) ? "eventhub" : "sidecar"
      platform_logs       = true
      location            = null
      platform_categories = null
      tier                = null
    }
  }

  platform_paths = {
    "platform-aks.cluster"           = try(local.dc["platform-aks"].cluster_id, null)
    "platform-messaging.namespace"   = try(local.dc["platform-messaging"].namespace_id, null)
    "platform-shared.acr"            = try(local.dc["platform-shared"].acr_id, null)
    "platform-db-postgresql.server"  = try(local.dc["platform-db-postgresql"].server.id, null)
    "platform-db-mysql.server"       = try(local.dc["platform-db-mysql"].server.id, null)
    "platform-db-sqlmi.server"       = try(local.dc["platform-db-sqlmi"].server.id, null)
    "platform-db-redis.cache"        = try(local.dc["platform-db-redis"].cache.id, null)
    "platform-batch.account"         = try(local.dc["platform-batch"].account_id, null)
    "platform-db-cosmos-nosql.acct"  = try(local.dc["platform-db-cosmos-nosql"].account.id, null)
    "platform-db-cosmos-mongo.acct"  = try(local.dc["platform-db-cosmos-mongo"].account.id, null)
    "platform-db-cosmos-cass.acct"   = try(local.dc["platform-db-cosmos-cassandra"].account.id, null)
    "platform-db-cosmos-gremlin.acc" = try(local.dc["platform-db-cosmos-gremlin"].account.id, null)
    "platform-db-cosmos-table.acct"  = try(local.dc["platform-db-cosmos-table"].account.id, null)
  }
  sql_db_paths = { for k, d in try(local.dc["platform-db-sql"].databases, {}) : "platform-db-sql.databases.${k}" => try(d.id, null) }

  platform_targets = {
    for k, id in merge(local.platform_paths, local.sql_db_paths) : k => { id = id, app_log_route = "none", platform_logs = true, location = null, platform_categories = null, tier = null }
    if id != null && startswith(coalesce(id, "-"), "/subscriptions/")
  }

  # Server-level SQL auditing (auditing policy with the Azure Monitor target) is delivered through a diagnostic
  # setting on the logical server's master database (Microsoft.Sql servers/auditingSettings isAzureMonitorTargetEnabled).
  sql_server_id = try(local.dc["platform-db-sql"].server.id, null)
  sql_master_targets = var.settings.sql_server_audit && local.sql_server_id != null && startswith(coalesce(local.sql_server_id, "-"), "/subscriptions/") ? {
    "platform-db-sql.master" = {
      id                  = "${local.sql_server_id}/databases/master"
      app_log_route       = "none"
      platform_logs       = true
      location            = null
      platform_categories = ["SQLSecurityAuditEvents", "DevOpsOperationsAudit"]
      tier                = null
    }
  } : {}

  # explicit var.resources wins on key collisions
  all_targets = merge(local.platform_targets, local.sql_master_targets, local.aca_env_targets, local.deploy_targets, var.resources)
}

check "aca_console_allow_covers_eventhub_apps" {
  assert {
    condition = alltrue([for n in local.aca_eventhub_apps : anytrue([
      for a in var.obs_telemetry_transport.fluentbit.aca_console_allow :
      endswith(a, "*") ? startswith(n, trimsuffix(a, "*")) : n == a
    ])]) || length(var.obs_telemetry_transport.fluentbit.aca_console_allow) == 0
    error_message = "Some Container Apps/Jobs with app_log_route = eventhub are not in obs-telemetry-transport fluentbit.aca_console_allow; the aggregator would drop their console logs. Add them to settings.aca_console_allow of obs-telemetry-transport."
  }
}
