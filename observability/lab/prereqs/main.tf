# obs-prereqs: Datadog objects that must exist BEFORE applications deploy. Today: the RUM application(s)
# whose id + client token are baked into the frontend's runtime config.json by deploy-frontend.
locals {
  rum_names = {
    for k, a in var.settings.rum_applications : k => "${var.environment.name_prefix}-${var.environment.name}-${k}"
  }
}

module "rum" {
  source = "../../modules/rum"
  applications = {
    for k, a in var.settings.rum_applications : k => { name = local.rum_names[k], type = a.type }
  }
}
