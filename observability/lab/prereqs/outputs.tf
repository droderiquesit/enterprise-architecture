output "contract" {
  description = "obs-prereqs contract v1 (catalog/contracts/obs-prereqs.v1.schema.json). No secrets (see README: client token)."
  value = {
    datadog_site = var.settings.datadog_site
    rum = {
      applications = {
        for k, a in var.settings.rum_applications : k => {
          application_id             = module.rum.applications[k].application_id
          client_token               = module.rum.applications[k].client_token
          name                       = module.rum.applications[k].name
          type                       = module.rum.applications[k].type
          site                       = var.settings.datadog_site
          service                    = coalesce(a.service, k)
          session_sample_rate        = a.session_sample_rate
          session_replay_sample_rate = a.session_replay_sample_rate
          default_privacy_level      = a.default_privacy_level
          track_user_interactions    = a.track_user_interactions
        }
      }
    }
  }
}
