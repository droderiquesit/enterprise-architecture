mock_provider "datadog" {
  mock_resource "datadog_rum_application" {
    defaults = { id = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb", client_token = "pubdeadbeefdeadbeefdeadbeefdeadbeef" }
  }
}

variables {
  environment = {
    name      = "dev", location = "swedencentral", subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id = "00000000-0000-0000-0000-000000000000", name_prefix = "eh", owner = "platform-team@example.com"
    team      = "platform-engineering", cost_center = "lab-0001", expires_on = "2026-12-31", tags = {}
  }
}

run "default_rum_application_and_contract" {
  command = apply

  assert {
    condition     = module.rum.applications["hello-frontend"].name == "eh-dev-hello-frontend"
    error_message = "RUM application name must be <prefix>-<env>-<key>"
  }
  assert {
    condition     = output.contract.rum.applications["hello-frontend"].application_id == "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
    error_message = "contract must expose the application id"
  }
  assert {
    condition     = output.contract.rum.applications["hello-frontend"].session_replay_sample_rate == 0
    error_message = "session replay is off by default"
  }
  assert {
    condition     = output.contract.datadog_site == "datadoghq.com"
    error_message = "site default"
  }
}

run "rejects_bad_sample_rate" {
  command = plan
  variables {
    settings = { rum_applications = { x = { session_sample_rate = 150 } } }
  }
  expect_failures = [var.settings]
}

run "existing_rum_application" {
  command = apply
  variables {
    settings = { rum_applications = { "hello-frontend" = { mode = "existing", application_id = "cccccccc-0000-0000-0000-000000000001", client_token = "pubexisting000000000000000000000000" } } }
  }
  assert {
    condition     = length(module.rum.applications) == 1 && output.contract.rum.applications["hello-frontend"].application_id == "cccccccc-0000-0000-0000-000000000001" && output.contract.rum.applications["hello-frontend"].client_token == "pubexisting000000000000000000000000"
    error_message = "existing RUM application: contract carries its ids, nothing is created"
  }
}
