mock_provider "datadog" {
  mock_resource "datadog_rum_application" {
    defaults = { id = "11111111-aaaa-bbbb-cccc-222222222222", client_token = "pub0123456789abcdef0123456789abcdef" }
  }
}

variables {
  applications = {
    storefront = {
      name                    = "storefront"
      env                     = "dev"
      version                 = "2.0.0"
      allowed_tracing_origins = ["https://api.example.com"]
      identity                = { team = "web", owner = "web@example.com" }
    }
  }
}

run "create_application_and_sdk_config" {
  command = apply

  assert {
    condition     = output.applications.storefront.application_id == "11111111-aaaa-bbbb-cccc-222222222222" && startswith(output.applications.storefront.client_token, "pub")
    error_message = "application id + browser-safe client token output"
  }
  assert {
    condition     = datadog_rum_application.this["storefront"].type == "browser"
    error_message = "default type is browser"
  }
  assert {
    condition     = output.browser_config.storefront.service == "storefront" && output.browser_config.storefront.env == "dev" && output.browser_config.storefront.version == "2.0.0"
    error_message = "unified service tags in the SDK init"
  }
  assert {
    condition     = output.browser_config.storefront.allowedTracingUrls[0].match == "https://api.example.com" && join(",", output.browser_config.storefront.allowedTracingUrls[0].propagatorTypes) == "tracecontext"
    error_message = "APM <-> RUM: W3C tracecontext propagator for first-party origins"
  }
  assert {
    condition     = output.browser_config.storefront.sessionReplaySampleRate == 0 && output.browser_config.storefront.globalContext["team"] == "web" && output.browser_config.storefront.globalContext["owner"] == "web_example.com"
    error_message = "replay off by default; tag-policy global context"
  }
}

run "existing_application" {
  command = apply
  variables {
    applications = {
      shop = { mode = "existing", application_id = "33333333-0000-0000-0000-000000000003", client_token = "pubexisting000000000000000000000000" }
    }
  }
  assert {
    condition     = length(datadog_rum_application.this) == 0 && output.applications.shop.application_id == "33333333-0000-0000-0000-000000000003" && output.browser_config.shop.clientToken == "pubexisting000000000000000000000000"
    error_message = "existing application: nothing created, ids passed through"
  }
}

run "rejects_existing_without_ids" {
  command = plan
  variables {
    applications = { x = { mode = "existing" } }
  }
  expect_failures = [var.applications]
}

run "rejects_unknown_type" {
  command = plan
  variables {
    applications = { x = { name = "x", type = "desktop" } }
  }
  expect_failures = [var.applications]
}

run "rejects_third_party_tracing_origin_pattern" {
  command = plan
  variables {
    applications = { x = { name = "x", allowed_tracing_origins = ["http://insecure.example.com"] } }
  }
  expect_failures = [var.applications]
}
