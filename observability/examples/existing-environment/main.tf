# Consumer root for an EXISTING environment. Uses only the vendored, versioned package release
# (./vendor.sh -> ./.vendor/observability-<version>/). Creates Datadog objects only; Azure resources are
# referenced by the ids written in manifests/<env>/*.yaml and are never created, changed or destroyed here.
locals {
  rendered_dir = "${path.module}/rendered/${var.env}"
  services     = [for f in sort(fileset(local.rendered_dir, "*.json")) : jsondecode(file("${local.rendered_dir}/${f}"))]

  # Every manifest resource gets platform-log diagnostic settings; the application resource of a service whose
  # log route is "eventhub" (App Service / Functions / Logic Apps) also exports its app-log categories.
  diagnostic_resources = merge([
    for s in local.services : {
      for r in s.resources : "${s.service}/${r.role}" => {
        id            = r.id
        app_log_route = r.role == "app" ? s.telemetry.logs.route : "none"
      }
    }
  ]...)
}

module "onboarding" {
  source = "./.vendor/observability-1.0.0/modules/onboarding"

  services   = local.services
  routing    = yamldecode(file("${path.module}/routing/${var.env}.yaml"))
  extra_tags = ["source:observability-package"]
  synthetics = var.synthetics
  dashboards = {
    overview_title = "[${var.env}] Orders - overview"
    journey        = ["orders-web", "orders-api"]
  }
  service_catalog = { system = "orders" }
}

module "azure_integration" {
  source = "./.vendor/observability-1.0.0/modules/azure-integration"
  count  = var.azure_integration.enabled ? 1 : 0

  mode             = "app_registration"
  tenant_id        = var.azure_integration.tenant_id
  subscription_ids = var.azure_integration.subscription_ids
  app_registration = {
    client_id                   = var.azure_integration.client_id
    auth                        = "secretless"
    service_principal_object_id = var.azure_integration.sp_object_id
    assign_monitoring_reader    = var.azure_integration.assign_monitoring_reader
  }
}

module "diagnostics" {
  source = "./.vendor/observability-1.0.0/modules/diagnostic-settings"
  count  = var.diagnostics.enabled ? 1 : 0

  resources = local.diagnostic_resources
  destination = {
    authorization_rule_id = var.diagnostics.destination.authorization_rule_id
    app_logs_hub          = var.diagnostics.destination.app_logs_hub
    platform_logs_hub     = var.diagnostics.destination.platform_logs_hub
  }
  platform_log_tier = var.diagnostics.platform_log_tier
}

# Subscription Activity Log (+ optional Entra ID) of the supplied subscriptions -> activity-logs hub.
module "azure_logs" {
  source = "./.vendor/observability-1.0.0/modules/azure-logs"
  count  = var.diagnostics.enabled ? 1 : 0

  activity_log = {
    enabled          = var.azure_logs.activity_log_enabled
    subscription_ids = var.azure_logs.subscription_ids
    categories       = var.azure_logs.categories
  }
  entra = var.azure_logs.entra
  destination = {
    authorization_rule_id = var.diagnostics.destination.authorization_rule_id
    eventhub_name         = coalesce(var.diagnostics.destination.activity_logs_hub, var.diagnostics.destination.platform_logs_hub)
  }
}

module "log_management" {
  source = "./.vendor/observability-1.0.0/modules/log-management"

  env       = var.env
  dashboard = { enabled = var.log_management.dashboard, entra = var.azure_logs.entra.enabled }
  metrics   = { enabled = var.log_management.metrics }
  index     = { enabled = var.log_management.index, name = "azure-platform-${var.env}" }
  pipeline  = { enabled = var.log_management.pipeline }
}

module "dbm" {
  source = "./.vendor/observability-1.0.0/modules/dbm"
  count  = var.dbm.enabled ? 1 : 0

  hosting = "cluster_checks"
  datadog = { site = var.datadog_site, env = var.env }
  databases = {
    orders-postgresql = {
      engine          = "postgres"
      deployment_type = "flexible_server"
      host            = var.dbm.host
      port            = 5432
      username        = "datadog"
      auth            = "password"
      password_ref    = { kind = "env", name = "DD_DBM_ORDERS_PG_PASSWORD" }
      resource_id     = var.dbm.resource_id
    }
  }
}

module "kubernetes" {
  source = "./.vendor/observability-1.0.0/modules/kubernetes"
  count  = var.kubernetes.enabled ? 1 : 0

  cluster_name = var.kubernetes.cluster_name
  datadog      = { site = var.datadog_site, env = var.env }
  api_key      = { mode = "existing" }

  cluster_checks = var.dbm.enabled ? module.dbm[0].cluster_check_confd : {}
  cluster_check_env = var.dbm.enabled ? {
    DD_DBM_ORDERS_PG_PASSWORD = { secret_name = var.dbm.password_secret, secret_key = "password" }
  } : {}
}

# Instrumentation hooks: env vars / app settings / k8s patches the application owners apply in their own
# deployment code (this root never changes application settings).
module "instrumentation" {
  source   = "./.vendor/observability-1.0.0/modules/instrumentation"
  for_each = var.instrumented_services

  service = {
    service = each.key
    env     = var.env
    version = each.value.version
    team    = each.value.team
  }
  runtime      = each.value.runtime
  architecture = each.value.architecture
  telemetry    = var.telemetry
}
