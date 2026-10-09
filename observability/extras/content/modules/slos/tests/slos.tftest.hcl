mock_provider "datadog" {
  mock_resource "datadog_service_level_objective" {
    defaults = { id = "abcdefabcdefabcdefabcdefabcdefab" }
  }
}

variables {
  route_handles = { team = ["@slack-team"] }
  slos = {
    "api/availability" = {
      display_name = "[prod] api availability"
      type         = "availability"
      target       = 99.9
      timeframe    = "30d"
      numerator    = "sum:trace.http.server.request.hits{service:api,env:prod}.as_count() - sum:trace.http.server.request.errors{service:api,env:prod}.as_count()"
      denominator  = "sum:trace.http.server.request.hits{service:api,env:prod}.as_count()"
      burn_rate_alerts = [{
        severity = "critical", name = "burn", message = "Runbook: https://x", long_window = "1h", short_window = "5m", threshold = 14.4
        notify   = { alert = ["team"] }
      }]
    }
    "api/latency" = {
      display_name = "[prod] api latency"
      type         = "latency"
      target       = 99
      timeframe    = "7d"
      time_slice   = { query = "p95:trace.http.server.request{service:api,env:prod}", comparator = "<=", threshold = 0.4 }
    }
  }
}

run "creates_metric_and_time_slice_slos_with_burn_rate" {
  command = apply

  assert {
    condition     = datadog_service_level_objective.this["api/availability"].type == "metric"
    error_message = "availability SLO is metric-based"
  }
  assert {
    condition     = datadog_service_level_objective.this["api/latency"].type == "time_slice"
    error_message = "latency SLO is time-slice"
  }
  assert {
    condition     = datadog_monitor.burn_rate["api/availability/critical-1h"].query == "burn_rate(\"abcdefabcdefabcdefabcdefabcdefab\").over(\"30d\").long_window(\"1h\").short_window(\"5m\") > 14.4"
    error_message = "burn-rate query syntax"
  }
  assert {
    condition     = datadog_monitor.burn_rate["api/availability/critical-1h"].type == "slo alert"
    error_message = "monitor type must be slo alert"
  }
}

run "rejects_impossible_burn_rate" {
  command = plan
  variables {
    slos = {
      "x/a" = {
        display_name     = "x", type = "availability", target = 95, timeframe = "30d", numerator = "a", denominator = "b"
        burn_rate_alerts = [{ severity = "critical", name = "n", message = "m", long_window = "1h", short_window = "5m", threshold = 21.6, notify = { alert = ["team"] } }]
      }
    }
  }
  expect_failures = [var.slos]
}
