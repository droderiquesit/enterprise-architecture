locals {
  # Private tests without a private location are skipped (reported in output skipped).
  runnable = {
    for k, t in var.tests : k => t if !t.private_location || var.private_location_id != null
  }
  locations = {
    for k, t in local.runnable : k => t.private_location ? [var.private_location_id] : t.locations
  }
}

resource "datadog_synthetics_test" "api" {
  for_each = { for k, t in local.runnable : k => t if t.kind == "api" }

  type      = "api"
  subtype   = "http"
  name      = each.value.name
  message   = "${each.value.message}\n\n${join(" ", each.value.handles)}"
  status    = var.paused ? "paused" : "live"
  locations = local.locations[each.key]
  tags      = sort(distinct(each.value.tags))

  request_definition {
    method  = "GET"
    url     = "${trimsuffix(each.value.url, "/")}${each.value.health_path}"
    timeout = 30
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = tostring(var.response_time_ms)
  }

  options_list {
    tick_every           = each.value.tick_every
    min_failure_duration = var.min_failure_duration
    min_location_failed  = var.min_location_failed
    follow_redirects     = true

    retry {
      count    = var.retry.count
      interval = var.retry.interval
    }

    monitor_options {
      renotify_interval = 0
    }
  }
}

resource "datadog_synthetics_test" "browser" {
  for_each = { for k, t in local.runnable : k => t if t.kind == "browser" }

  type       = "browser"
  name       = each.value.name
  message    = "${each.value.message}\n\n${join(" ", each.value.handles)}"
  status     = var.paused ? "paused" : "live"
  locations  = local.locations[each.key]
  device_ids = var.browser_device_ids
  tags       = sort(distinct(each.value.tags))

  request_definition {
    method = "GET"
    url    = each.value.url
  }

  dynamic "browser_step" {
    for_each = each.value.browser_steps
    content {
      name = browser_step.value.name
      type = browser_step.value.type
      params {
        value = browser_step.value.value
      }
    }
  }

  options_list {
    tick_every           = each.value.tick_every
    min_failure_duration = var.min_failure_duration
    min_location_failed  = var.min_location_failed

    retry {
      count    = var.retry.count
      interval = var.retry.interval
    }

    monitor_options {
      renotify_interval = 0
    }
  }
}
