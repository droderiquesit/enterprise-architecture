mock_provider "datadog" {}

variables {
  tests = {
    "api/public" = { kind = "api", name = "t", url = "https://api.example.com/", health_path = "/healthz", locations = ["aws:eu-central-1"], message = "Runbook: https://x", handles = ["@slack-x"] }
  }
}

run "api_test_shape" {
  command = plan
  assert {
    condition     = datadog_synthetics_test.api["api/public"].request_definition[0].url == "https://api.example.com/healthz"
    error_message = "URL must join base and health path"
  }
  assert {
    condition     = datadog_synthetics_test.api["api/public"].status == "paused"
    error_message = "paused by default"
  }
}

run "live_when_not_paused" {
  command = plan
  variables {
    paused = false
  }
  assert {
    condition     = datadog_synthetics_test.api["api/public"].status == "live"
    error_message = "live expected"
  }
}

run "rejects_relative_url" {
  command = plan
  variables {
    tests = { "x/y" = { kind = "api", name = "t", url = "$${contract:a.b}", message = "m", handles = [] } }
  }
  expect_failures = [var.tests]
}
