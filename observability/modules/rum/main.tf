# Datadog RUM for browser frontends: the application (created here or an existing one) + the browser SDK init the
# frontend deployment renders into its runtime config (APM <-> RUM: allowedTracingUrls with the datadog and W3C
# tracecontext propagators for first-party API origins only; unified service tags; tag-policy global context).
module "fleet" {
  source       = "../fleet-policy"
  policy       = var.fleet_policy
  architecture = "swa"
  runtime      = "browser"
}

module "tags" {
  source           = "../tagging"
  for_each         = var.applications
  policy           = var.tag_policy
  identity         = merge(each.value.identity, { service = coalesce(each.value.service, each.key) }, each.value.env == null ? {} : { env = each.value.env }, each.value.version == null ? {} : { version = each.value.version })
  enforce_required = false
}

resource "datadog_rum_application" "this" {
  for_each = { for k, a in var.applications : k => a if a.mode == "create" }

  name = each.value.name
  type = each.value.type
}

locals {
  rum = module.fleet.rum
  apps = { for k, a in var.applications : k => {
    application_id = a.mode == "create" ? datadog_rum_application.this[k].id : a.application_id
    client_token   = a.mode == "create" ? datadog_rum_application.this[k].client_token : a.client_token
    name           = a.mode == "create" ? datadog_rum_application.this[k].name : coalesce(a.name, k)
    type           = a.type
    mode           = a.mode
  } }
  browser_config = { for k, a in var.applications : k => {
    applicationId           = local.apps[k].application_id
    clientToken             = local.apps[k].client_token
    site                    = var.datadog_site
    service                 = module.tags[k].unified.service
    env                     = module.tags[k].unified.env
    version                 = module.tags[k].unified.version
    sessionSampleRate       = try(local.rum.session_sample_rate, 100)
    sessionReplaySampleRate = try(local.rum.session_replay_sample_rate, 0)
    traceSampleRate         = try(local.rum.trace_sample_rate, 100)
    defaultPrivacyLevel     = try(local.rum.default_privacy_level, "mask-user-input")
    trackUserInteractions   = try(local.rum.track_user_interactions, true)
    trackResources          = try(local.rum.track_resources, true)
    trackLongTasks          = try(local.rum.track_long_tasks, true)
    allowedTracingUrls      = [for o in a.allowed_tracing_origins : { match = o, propagatorTypes = try(local.rum.propagator_types, ["datadog", "tracecontext"]) }]
    # datadogRum.setGlobalContextProperty(k, v) for every entry (tag policy keys besides env/service/version)
    globalContext = module.tags[k].rum_global_context
  } }
}
