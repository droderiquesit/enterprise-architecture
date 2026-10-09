module "diagnostics" {
  source = "../../modules/diagnostic-settings"

  resources = { for k, r in var.resources : k => {
    id            = r.id
    app_log_route = r.app_log_route
    platform_logs = r.platform_logs
    location      = r.location
  } }
  destination = {
    authorization_rule_id = var.obs_telemetry_transport.event_hub.authorization_rule_id
    app_logs_hub          = var.obs_telemetry_transport.event_hub.app_logs_hub
    platform_logs_hub     = var.obs_telemetry_transport.event_hub.platform_logs_hub
    location              = var.obs_telemetry_transport.event_hub.location
  }
  setting_name_prefix = var.settings.setting_name_prefix
  platform_log_allowlist = merge({
    "microsoft.web/sites"                        = ["AppServiceHTTPLogs", "AppServicePlatformLogs", "AppServiceAuditLogs", "AppServiceIPSecAuditLogs", "AppServiceAuthenticationLogs"]
    "microsoft.web/sites/slots"                  = ["AppServiceHTTPLogs", "AppServicePlatformLogs"]
    "microsoft.app/managedenvironments"          = ["ContainerAppSystemLogs"]
    "microsoft.logic/workflows"                  = []
    "microsoft.containerservice/managedclusters" = ["kube-audit-admin", "cluster-autoscaler", "guard"]
    "microsoft.sql/servers/databases"            = ["SQLSecurityAuditEvents", "Errors", "Timeouts", "Blocks", "Deadlocks", "AutomaticTuning"]
    "microsoft.sql/managedinstances"             = ["SQLSecurityAuditEvents", "ResourceUsageStats"]
    "microsoft.dbforpostgresql/flexibleservers"  = ["PostgreSQLLogs", "PostgreSQLFlexSessions"]
    "microsoft.dbformysql/flexibleservers"       = ["MySqlSlowLogs", "MySqlAuditLogs"]
    "microsoft.documentdb/databaseaccounts"      = ["ControlPlaneRequests"]
    "microsoft.keyvault/vaults"                  = ["AuditEvent"]
    "microsoft.servicebus/namespaces"            = ["OperationalLogs", "RuntimeAuditLogs"]
    "microsoft.eventhub/namespaces"              = ["OperationalLogs"]
    "microsoft.network/applicationgateways"      = ["ApplicationGatewayAccessLog", "ApplicationGatewayFirewallLog"]
    "microsoft.cdn/profiles"                     = ["FrontDoorAccessLog", "FrontDoorWebApplicationFirewallLog"]
    "microsoft.apimanagement/service"            = ["GatewayLogs"]
    "microsoft.containerregistry/registries"     = ["ContainerRegistryLoginEvents"]
  }, var.settings.platform_log_allowlist_overrides)
}
