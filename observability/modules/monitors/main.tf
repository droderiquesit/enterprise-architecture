locals {
  unknown_routes = sort(distinct(flatten([
    for m in values(var.monitors) : [for r in concat(m.notify.alert, m.notify.warning) : r if !contains(keys(var.route_handles), r)]
  ])))

  messages = {
    for k, m in var.monitors : k => join("\n", compact([
      m.message,
      "",
      format("{{#is_alert}}%s{{/is_alert}}", join(" ", distinct(flatten([for r in m.notify.alert : lookup(var.route_handles, r, [])])))),
      length(m.notify.warning) > 0 ? format("{{#is_warning}}%s{{/is_warning}}", join(" ", distinct(flatten([for r in m.notify.warning : lookup(var.route_handles, r, [])])))) : "",
      format("{{#is_no_data}}%s{{/is_no_data}}", join(" ", distinct(flatten([for r in m.notify.alert : lookup(var.route_handles, r, [])])))),
      format("{{#is_recovery}}%s{{/is_recovery}}", join(" ", distinct(flatten([for r in m.notify.alert : lookup(var.route_handles, r, [])])))),
    ]))
  }
}

resource "datadog_monitor" "this" {
  for_each = var.monitors

  name                = each.value.name
  type                = each.value.type
  query               = each.value.query
  message             = local.messages[each.key]
  priority            = tostring(each.value.priority)
  tags                = sort(distinct(concat(each.value.tags, var.extra_tags)))
  notify_no_data      = each.value.notify_no_data
  no_data_timeframe   = each.value.notify_no_data ? each.value.no_data_timeframe : null
  require_full_window = each.value.require_full_window
  evaluation_delay    = each.value.evaluation_delay
  # Only multi-alert (grouped) monitors accept new_group_delay; Datadog rejects it on simple alerts.
  new_group_delay   = can(regex("(?i)\\bby\\s*\\{", each.value.query)) ? each.value.new_group_delay : null
  renotify_interval = each.value.renotify_interval
  include_tags      = true

  monitor_thresholds {
    critical          = tostring(each.value.thresholds.critical)
    warning           = each.value.thresholds.warning == null ? null : tostring(each.value.thresholds.warning)
    critical_recovery = each.value.thresholds.critical_recovery == null ? null : tostring(each.value.thresholds.critical_recovery)
    warning_recovery  = each.value.thresholds.warning_recovery == null ? null : tostring(each.value.thresholds.warning_recovery)
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_routes) == 0
      error_message = "Monitors reference route keys missing from the notification routing: ${join(", ", local.unknown_routes)}."
    }
  }
}
