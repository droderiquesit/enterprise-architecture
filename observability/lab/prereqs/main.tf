# obs-prereqs: RUM application(s) that must exist before deploy-frontend bakes their id + client token into config.json.
locals {
  rum_names = {
    for k, a in var.settings.rum_applications : k => "${var.environment.name_prefix}-${var.environment.name}-${k}"
  }
}

module "rum" {
  source       = "../../modules/rum"
  datadog_site = var.settings.datadog_site
  applications = {
    for k, a in var.settings.rum_applications : k => {
      mode           = a.mode
      name           = local.rum_names[k]
      type           = a.type
      application_id = a.application_id
      client_token   = a.client_token
      service        = coalesce(a.service, k)
      env            = var.environment.name
    }
  }
}
