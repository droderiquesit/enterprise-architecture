mock_provider "datadog" {
  mock_resource "datadog_rum_application" {
    defaults = { id = "11111111-aaaa-bbbb-cccc-222222222222", client_token = "pub0123456789abcdef0123456789abcdef" }
  }
}

variables {
  applications = { storefront = { name = "storefront" } }
}

run "outputs_application_id_and_browser_token" {
  command = apply

  assert {
    condition     = output.applications.storefront.application_id == "11111111-aaaa-bbbb-cccc-222222222222"
    error_message = "application id must be output"
  }
  assert {
    condition     = startswith(output.applications.storefront.client_token, "pub")
    error_message = "client token must be output (browser-safe)"
  }
  assert {
    condition     = datadog_rum_application.this["storefront"].type == "browser"
    error_message = "default type is browser"
  }
}

run "rejects_unknown_type" {
  command = plan
  variables {
    applications = { x = { name = "x", type = "desktop" } }
  }
  expect_failures = [var.applications]
}
