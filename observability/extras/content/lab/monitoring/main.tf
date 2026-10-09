# obs-monitoring (lab): thin consumer of the portable package. Reads the COMMITTED rendered onboarding
# output (render.py; CI verifies it is current), resolves contract references and onboards every
# Enterprise Hello service that is deployed in this environment.
locals {
  rendered_dir = coalesce(var.settings.rendered_dir, "${path.module}/../../onboarding/rendered/${var.environment.name}")
  routing_file = coalesce(var.settings.routing_file, "${path.module}/../../onboarding/routing/${var.environment.name}.yaml")
  services     = [for f in sort(fileset(local.rendered_dir, "*.json")) : jsondecode(file("${local.rendered_dir}/${f}"))]

  # obs-prereqs is a typed contract variable; expose its RUM ids to manifests as references too.
  prereq_refs = merge([
    for k, a in var.obs_prereqs.rum.applications : {
      "obs-prereqs.rum.applications.${k}.application_id" = a.application_id
      "obs-prereqs.rum.applications.${k}.name"           = a.name
    }
  ]...)
}

module "onboarding" {
  source = "../../modules/onboarding"

  services            = local.services
  contract_references = merge(var.contract_references, local.prereq_refs)
  routing             = yamldecode(file(local.routing_file))
  create_webhooks     = var.settings.create_webhooks
  slos_enabled        = var.settings.slos_enabled
  extra_tags          = ["application:enterprise-hello", "component:obs-monitoring"]

  synthetics = {
    enabled             = var.settings.synthetics_enabled
    paused              = var.settings.synthetics_paused
    private_location_id = var.settings.private_location_id
  }
  dashboards = {
    service_dashboards = var.settings.service_dashboards
    overview           = var.settings.overview_dashboard
    overview_title     = "[${var.environment.name}] Enterprise Hello - overview"
    journey            = var.settings.journey
  }
  service_catalog = {
    enabled = var.settings.service_catalog
    system  = var.settings.service_catalog ? "enterprise-hello" : null
  }
}
