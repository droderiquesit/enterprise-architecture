# obs-prereqs: Datadog objects that must exist BEFORE applications deploy: the RUM application(s) whose id + client
# token are baked into the frontend's runtime config.json by deploy-frontend. Default: created here
# (datadog_rum_application); settings.rum_applications.<key>.mode = existing uses an application the organisation
# already has (application_id + client_token) and creates nothing.
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
