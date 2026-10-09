mock_provider "datadog" {}

variables {
  route_handles = { team = ["@slack-team"], pager = ["@pagerduty-x"] }
  monitors = {
    "api/apm.error_rate" = {
      name       = "n", type = "query alert", query = "sum(last_10m):sum:trace.http.server.request.errors{service:api}.as_count() > 5"
      message    = "x\n\nRunbook: https://rb/api#error-rate"
      thresholds = { critical = 5, warning = 2 }
      notify     = { alert = ["pager"], warning = ["team"] }
    }
  }
}

run "composes_message_with_handles" {
  command = plan
  assert {
    condition     = strcontains(datadog_monitor.this["api/apm.error_rate"].message, "{{#is_alert}}@pagerduty-x{{/is_alert}}") && strcontains(datadog_monitor.this["api/apm.error_rate"].message, "{{#is_warning}}@slack-team{{/is_warning}}")
    error_message = "handles per state expected"
  }
  assert {
    condition     = datadog_monitor.this["api/apm.error_rate"].monitor_thresholds[0].critical == "5"
    error_message = "critical threshold"
  }
}

run "unknown_route_fails" {
  command = plan
  variables {
    route_handles = { team = ["@slack-team"] }
  }
  expect_failures = [datadog_monitor.this]
}

run "missing_runbook_rejected" {
  command = plan
  variables {
    monitors = {
      "a/b" = { name = "n", type = "query alert", query = "q > 1", message = "no link", thresholds = { critical = 1 }, notify = { alert = ["team"] } }
    }
  }
  expect_failures = [var.monitors]
}

run "new_group_delay_only_on_grouped_monitors" {
  command = plan
  variables {
    monitors = {
      simple = {
        name            = "simple"
        type            = "log alert"
        query           = "logs(\"service:telemetry-canary\").index(\"*\").rollup(\"count\").last(\"10m\") < 1"
        message         = "m Runbook: https://example.invalid/rb"
        new_group_delay = 60
        thresholds      = { critical = 1 }
        notify          = { alert = ["team"] }
      }
      grouped = {
        name            = "grouped"
        type            = "query alert"
        query           = "avg(last_5m):avg:system.cpu.user{*} by {host} > 90"
        message         = "m Runbook: https://example.invalid/rb"
        new_group_delay = 60
        thresholds      = { critical = 90 }
        notify          = { alert = ["team"] }
      }
    }
  }
  assert {
    condition     = datadog_monitor.this["simple"].new_group_delay == null && datadog_monitor.this["grouped"].new_group_delay == 60
    error_message = "new_group_delay must only be sent for grouped (multi-alert) monitors."
  }
}
