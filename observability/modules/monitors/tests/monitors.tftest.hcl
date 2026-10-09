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
