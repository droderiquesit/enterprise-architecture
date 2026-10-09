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

  resources   = local.diagnostic_resources
  destination = var.diagnostics.destination
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
