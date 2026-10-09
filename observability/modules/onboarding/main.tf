# Composition: rendered service documents -> notification routing, monitors, SLOs + burn-rate alerts,
# synthetics, dashboards, Software Catalog entities and quiet-hours downtimes.
# Reference resolution here mirrors tools/onboarding/render.py --contracts-dir exactly:
#   whole-string "$${contract:<key>}" -> contract_references[<key>]; unresolved optional -> dropped;
#   unresolved required -> plan fails (output precondition) when strict_references = true.
locals {
  ref_re = "^\\$\\{contract:([^}]+)\\}$"
  arm_re = "(?i)^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/[^/]+/.+$"

  all_services = { for s in var.services : s.service => s }
  present = {
    for name, s in local.all_services : name => s
    if s.enabled && (try(s.presence_ref, null) == null || contains(keys(var.contract_references), try(s.presence_ref, "")))
  }
  skipped_services = sort([for name in keys(local.all_services) : name if !contains(keys(local.present), name)])

  # ---------------------------------------------------------------- resources
  resource_rows = flatten([
    for name, s in local.present : [
      for r in s.resources : {
        service  = name
        role     = r.role
        type     = r.type
        required = r.required
        ref      = length(regexall(local.ref_re, r.id)) > 0 ? regex(local.ref_re, r.id)[0] : null
        raw      = r.id
      }
    ]
  ])
  resource_resolved = [
    for r in local.resource_rows : merge(r, { id = r.ref == null ? r.raw : lookup(var.contract_references, r.ref, null) })
  ]
  missing_required = sort(concat(
    [for r in local.resource_resolved : "${r.service}/resource ${r.role} -> $${contract:${r.ref}}" if r.id == null && r.required],
    [for e in local.endpoint_resolved : "${e.service}/endpoint ${e.name} -> $${contract:${e.ref}}" if e.url == null && e.required],
  ))
  invalid_ids = sort([for r in local.resource_resolved : "${r.service}/${r.role}: ${r.id}" if r.id != null && !can(regex(local.arm_re, coalesce(r.id, "x")))])
  dropped_optional = sort(concat(
    [for r in local.resource_resolved : "${r.service}/resource ${r.role}" if r.id == null && !r.required],
    [for e in local.endpoint_resolved : "${e.service}/endpoint ${e.name}" if e.url == null && !e.required],
  ))

  resources = {
    for r in local.resource_resolved : "${r.service}/${r.role}" => merge(r, {
      parts = split("/", r.id)
      name  = element(split("/", r.id), length(split("/", r.id)) - 1)
      scope = lower(join(",", compact([
        "subscription_id:${split("/", r.id)[2]}",
        "resource_group:${split("/", r.id)[4]}",
        lower(r.type) == "microsoft.sql/servers/databases" ? "server_name:${split("/", r.id)[8]}" : "",
        "name:${element(split("/", r.id), length(split("/", r.id)) - 1)}",
      ])))
    }) if r.id != null && can(regex(local.arm_re, coalesce(r.id, "x")))
  }

  # ---------------------------------------------------------------- endpoints
  endpoint_rows = flatten([
    for name, s in local.present : [
      for e in s.endpoints : merge(e, {
        service = name
        ref     = length(regexall(local.ref_re, e.url)) > 0 ? regex(local.ref_re, e.url)[0] : null
      })
    ]
  ])
  endpoint_resolved = [
    for e in local.endpoint_rows : merge(e, { url = e.ref == null ? e.url : lookup(var.contract_references, e.ref, null) })
  ]

  # ---------------------------------------------------------------- monitors
  monitor_rows = flatten([
    for name, s in local.present : [
      for k, m in s.monitors : {
        key = "${name}/${k}"
        svc = name
        m   = m
        res = m.resource_role == null ? null : lookup(local.resources, "${name}/${m.resource_role}", null)
      }
    ]
  ])
  monitors = {
    for row in local.monitor_rows : row.key => {
      name                = row.res == null ? row.m.name : replace(replace(replace(replace(row.m.name, "[[resource.scope]]", row.res.scope), "[[resource.name]]", row.res.name), "[[resource.role]]", row.res.role), "[[resource.id]]", row.res.id)
      query               = row.res == null ? row.m.query : replace(replace(replace(replace(row.m.query, "[[resource.scope]]", row.res.scope), "[[resource.name]]", row.res.name), "[[resource.role]]", row.res.role), "[[resource.id]]", row.res.id)
      message             = row.res == null ? row.m.message : replace(replace(replace(replace(row.m.message, "[[resource.scope]]", row.res.scope), "[[resource.name]]", row.res.name), "[[resource.role]]", row.res.role), "[[resource.id]]", row.res.id)
      type                = row.m.type
      priority            = row.m.priority
      tags                = row.res == null ? row.m.tags : concat(row.m.tags, ["resource_role:${row.res.role}"])
      notify_no_data      = row.m.notify_no_data
      no_data_timeframe   = row.m.no_data_timeframe
      require_full_window = row.m.require_full_window
      evaluation_delay    = row.m.evaluation_delay
      new_group_delay     = row.m.new_group_delay
      renotify_interval   = row.m.renotify_interval
      thresholds = {
        critical          = row.m.thresholds.critical
        warning           = try(row.m.thresholds.warning, null)
        critical_recovery = try(row.m.thresholds.critical_recovery, null)
        warning_recovery  = try(row.m.thresholds.warning_recovery, null)
      }
      notify = { alert = row.m.notify.alert, warning = row.m.notify.warning }
    } if row.m.resource_role == null || row.res != null
  }

  # ---------------------------------------------------------------- SLOs
  slos = { for k, v in merge([
    for name, s in local.present : {
      for slo in s.slos : "${name}/${slo.name}" => {
        display_name     = slo.display_name
        description      = slo.description
        type             = slo.type
        target           = slo.target
        warning          = slo.warning
        timeframe        = slo.timeframe
        tags             = slo.tags
        numerator        = try(slo.numerator, null)
        denominator      = try(slo.denominator, null)
        time_slice       = try(slo.time_slice, null)
        burn_rate_alerts = slo.burn_rate_alerts
      }
    }
  ]...) : k => v if var.slos_enabled }

  # ---------------------------------------------------------------- synthetics
  synthetic_tests = { for k, v in merge(
    {
      for e in local.endpoint_resolved : "${e.service}/${e.name}" => {
        kind             = "api"
        name             = "[${local.present[e.service].env}] ${e.service} ${e.name} health"
        url              = e.url
        health_path      = e.health_path
        locations        = e.synthetic.locations
        private_location = e.synthetic.private_location
        tick_every       = e.synthetic.tick_every
        tags             = local.present[e.service].tags
        message          = "Synthetic health check of ${e.service} (${e.name}) failed.\n\nTroubleshooting:\n1. Open the test result (status code, timings, TLS).\n2. Compare with the service error-rate monitor and the platform 5xx monitor.\n\nRunbook: ${local.present[e.service].metadata.runbook_url}#synthetics"
        handles          = distinct(flatten([for r in try(local.present[e.service].notifications.critical, ["default"]) : lookup(module.routing.route_handles, r, [])]))
        browser_steps    = []
      } if e.url != null && e.synthetic.enabled
    },
    {
      for e in local.endpoint_resolved : "${e.service}/${e.name}/browser" => {
        kind             = "browser"
        name             = "[${local.present[e.service].env}] ${e.service} ${e.name} browser journey"
        url              = e.url
        health_path      = "/"
        locations        = e.synthetic.locations
        private_location = e.synthetic.private_location
        tick_every       = max(e.synthetic.tick_every, 900)
        tags             = local.present[e.service].tags
        message          = "Browser journey for ${e.service} failed.\n\nTroubleshooting:\n1. Open the step screenshots and the RUM session linked to the test.\n\nRunbook: ${local.present[e.service].metadata.runbook_url}#synthetics"
        handles          = distinct(flatten([for r in try(local.present[e.service].notifications.critical, ["default"]) : lookup(module.routing.route_handles, r, [])]))
        browser_steps    = e.browser_steps
      } if e.url != null && e.synthetic.enabled && e.browser_journey
    },
  ) : k => v if var.synthetics.enabled }

  # ---------------------------------------------------------------- dashboards / catalog / downtimes
  dashboard_services = {
    for name, s in local.present : name => {
      env                    = s.env
      team                   = s.metadata.team
      architecture           = s.architecture
      traces_enabled         = s.telemetry.traces.enabled
      rum_enabled            = try(s.telemetry.rum.enabled, false)
      logs_enabled           = try(s.telemetry.logs.route, "none") != "none"
      server_operation       = try(s.telemetry.traces.server_operation, "http.server.request")
      workflow_metric_prefix = try(s.dashboards.workflow_metric_prefix, null)
      runbook_url            = s.metadata.runbook_url
      slo_ids                = [for k, id in module.slos.ids : id if startswith(k, "${name}/")]
      resources              = [for k, r in local.resources : { role = r.role, type = r.type, scope = r.scope } if r.service == name]
    } if s.dashboards.enabled
  }
  envs = distinct([for s in local.present : s.env])

  quiet = { for name, s in local.present : name => s.idle_behavior.expected_quiet_hours if try(s.idle_behavior.expected_quiet_hours, null) != null }
}

module "routing" {
  source          = "../notification-routing"
  routing         = var.routing
  create_webhooks = var.create_webhooks
}

module "monitors" {
  source        = "../monitors"
  monitors      = local.monitors
  route_handles = module.routing.route_handles
  extra_tags    = var.extra_tags
}

module "slos" {
  source        = "../slos"
  slos          = local.slos
  route_handles = module.routing.route_handles
}

module "synthetics" {
  source              = "../synthetics"
  tests               = local.synthetic_tests
  paused              = var.synthetics.paused
  private_location_id = var.synthetics.private_location_id
  response_time_ms    = var.synthetics.response_time_ms
}

module "dashboards" {
  source                    = "../dashboards"
  services                  = local.dashboard_services
  create_service_dashboards = var.dashboards.service_dashboards
  overview = {
    enabled        = var.dashboards.overview && length(local.present) > 0
    title          = coalesce(var.dashboards.overview_title, "[${join(",", local.envs)}] application overview")
    env            = join(",", local.envs)
    journey        = [for s in var.dashboards.journey : s if contains(keys(local.present), s)]
    pipeline_scope = var.dashboards.pipeline_scope
  }
}

module "catalog" {
  source = "../service-catalog"
  services = var.service_catalog.enabled ? {
    for name, s in local.present : name => {
      display_name = s.metadata.display_name
      description  = s.metadata.description
      team         = s.metadata.team
      owner        = s.metadata.owner
      env          = s.env
      tier         = s.metadata.tier
      lifecycle    = s.catalog.lifecycle
      type         = s.catalog.type
      languages    = s.metadata.languages
      depends_on   = s.metadata.depends_on
      component_of = s.catalog.component_of
      repository   = s.metadata.repository
      runbook_url  = s.metadata.runbook_url
      tags         = [for t in s.tags : t if !startswith(t, "env:")]
      contacts     = s.metadata.contacts
    } if s.catalog.enabled
  } : {}
  systems = var.service_catalog.enabled && var.service_catalog.system != null ? {
    (var.service_catalog.system) = {
      owner      = "platform"
      components = [for name in keys(local.present) : "service:${name}"]
    }
  } : {}
}

# Expected quiet hours: mute this service's monitors on a recurring schedule instead of disabling no-data.
resource "datadog_downtime_schedule" "quiet_hours" {
  for_each = local.quiet

  scope   = "env:${local.present[each.key].env}"
  message = "Expected quiet hours for ${each.key} (onboarding manifest idle_behavior.expected_quiet_hours)."

  monitor_identifier {
    monitor_tags = ["service:${each.key}", "env:${local.present[each.key].env}", "managed_by:observability-package"]
  }

  recurring_schedule {
    timezone = each.value.timezone
    recurrence {
      rrule    = each.value.rrule
      duration = each.value.duration
      start    = try(each.value.start, null)
    }
  }
}
