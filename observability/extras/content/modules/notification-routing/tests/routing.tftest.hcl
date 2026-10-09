mock_provider "datadog" {}

run "maps_routes" {
  command = plan
  variables {
    routing = {
      metadata = { env = "prod" }
      routes = {
        team  = { handles = ["@slack-team"] }
        pager = { handles = ["@pagerduty-svc", "@slack-team"] }
      }
    }
  }
  assert {
    condition     = output.route_handles["pager"] == tolist(["@pagerduty-svc", "@slack-team"])
    error_message = "handles must be passed through"
  }
  assert {
    condition     = length(datadog_webhook.this) == 0
    error_message = "webhooks are opt-in"
  }
}

run "rejects_raw_text_handle" {
  command = plan
  variables {
    routing = { metadata = { env = "prod" }, routes = { bad = { handles = ["slack-team"] } } }
  }
  expect_failures = [var.routing]
}

run "creates_webhook_when_enabled" {
  command = plan
  variables {
    create_webhooks = true
    routing = {
      metadata = { env = "prod" }
      routes   = { hook = { handles = ["@webhook-itsm"] } }
      webhooks = { itsm = { url = "https://itsm.example.com/hook" } }
    }
  }
  assert {
    condition     = datadog_webhook.this["itsm"].url == "https://itsm.example.com/hook"
    error_message = "webhook expected"
  }
}
