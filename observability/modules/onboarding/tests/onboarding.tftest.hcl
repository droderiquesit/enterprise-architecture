# Plan-only tests with a mocked Datadog provider. Fixtures are rendered by tools/onboarding/render.py
# from tests/fixtures/manifests (tests/content checks they are up to date).
mock_provider "datadog" {
  mock_resource "datadog_service_level_objective" {
    defaults = { id = "0123456789abcdef0123456789abcdef" }
  }
  mock_resource "datadog_dashboard_json" {
    defaults = { url = "/dashboard/abc-def-ghi" }
  }
}

variables {
  services = [
    jsondecode(file("tests/fixtures/rendered/test/shop-api.json")),
    jsondecode(file("tests/fixtures/rendered/test/storefront.json")),
    jsondecode(file("tests/fixtures/rendered/test/telemetry-pipeline.json")),
  ]
  routing = yamldecode(file("tests/fixtures/routing.yaml"))
  dashboards = {
    journey = ["storefront", "shop-api"]
  }
  service_catalog = { system = "shop" }
}

run "onboards_with_literal_ids_and_drops_optional_reference" {
  command = plan

  assert {
    condition     = output.summary.services == tolist(["shop-api", "storefront", "telemetry-pipeline"])
    error_message = "all three services must be onboarded"
  }
  assert {
    condition     = output.summary.dropped_optional == tolist(["shop-api/resource bus"])
    error_message = "the unresolved optional Service Bus reference must be dropped"
  }
  assert {
    condition     = length([for k in keys(module.monitors.ids) : k if strcontains(k, "@bus")]) == 0
    error_message = "no monitor may target a dropped resource"
  }
  assert {
    condition     = output.resources["shop-api/db"].id == "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-data/providers/Microsoft.Sql/servers/sql-shop/databases/shopdb"
    error_message = "supplied resource ids must be used verbatim"
  }
  assert {
    condition     = output.resources["shop-api/db"].scope == "subscription_id:11111111-2222-3333-4444-555555555555,resource_group:rg-data,server_name:sql-shop,name:shopdb"
    error_message = "SQL database scope must include server_name and lower-cased tags"
  }
  assert {
    condition     = output.resources["shop-api/app"].scope == "subscription_id:11111111-2222-3333-4444-555555555555,resource_group:rg-shop,name:app-shop-api"
    error_message = "resource group tag must be lower-cased"
  }
  assert {
    condition     = strcontains(module.monitors.datadog_monitor_queries["shop-api/sql.cpu@db"], "{subscription_id:11111111-2222-3333-4444-555555555555,resource_group:rg-data,server_name:sql-shop,name:shopdb}")
    error_message = "resource placeholder must be replaced in the query"
  }
  assert {
    condition     = alltrue([for k, m in module.monitors.messages : strcontains(m, "Runbook: https://")])
    error_message = "every monitor message must carry a runbook link"
  }
  assert {
    condition     = alltrue([for k, m in module.monitors.messages : strcontains(m, "@")])
    error_message = "every monitor message must carry at least one notification handle"
  }
  assert {
    condition     = strcontains(module.monitors.messages["shop-api/apm.error_rate"], "{{#is_alert}}@slack-shop-alerts @pagerduty-shop{{/is_alert}}")
    error_message = "critical monitors must page via the 'pager' route"
  }
  assert {
    condition     = !contains(keys(module.monitors.ids), "shop-api/appsvc.response_time@app")
    error_message = "disabled monitors must not be created"
  }
  assert {
    condition     = length(module.slos.burn_rate_monitor_ids) == 4
    error_message = "two SLOs x two burn-rate windows expected"
  }
  assert {
    condition     = keys(module.synthetics.api_test_ids) == ["shop-api/api", "storefront/site"]
    error_message = "public endpoints get API tests; the private endpoint is skipped without a private location"
  }
  assert {
    condition     = module.synthetics.skipped == tolist(["shop-api/internal"])
    error_message = "private endpoint must be reported as skipped"
  }
  assert {
    condition     = keys(module.synthetics.browser_test_ids) == ["storefront/site/browser"]
    error_message = "frontend browser journey expected"
  }
  assert {
    condition     = length(datadog_downtime_schedule.quiet_hours) == 1
    error_message = "quiet hours must create one recurring downtime"
  }
  assert {
    condition     = contains(keys(module.catalog.entity_ids), "system:shop")
    error_message = "system entity expected"
  }
}

run "private_location_enables_private_tests_and_tests_paused_by_default" {
  command = plan

  variables {
    synthetics = { private_location_id = "pl:shop-private-abc123" }
  }

  assert {
    condition     = contains(keys(module.synthetics.api_test_ids), "shop-api/internal")
    error_message = "private endpoint test expected when a private location is supplied"
  }
  assert {
    condition     = module.synthetics.statuses["shop-api/internal"] == "paused"
    error_message = "tests default to paused"
  }
  assert {
    condition     = tolist(module.synthetics.locations["shop-api/internal"]) == tolist(["pl:shop-private-abc123"])
    error_message = "private tests run only from the private location"
  }
}

run "resolves_contract_reference" {
  command = plan

  variables {
    contract_references = {
      "platform-messaging.namespace_id" = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/sb-shop"
    }
  }

  assert {
    condition     = length(output.summary.dropped_optional) == 0
    error_message = "reference must resolve"
  }
  assert {
    condition     = contains(keys(module.monitors.ids), "shop-api/queue.backlog@bus")
    error_message = "queue monitors appear once the namespace resolves"
  }
}

run "missing_required_reference_fails" {
  command = plan

  variables {
    services = [jsondecode(file("tests/fixtures/rendered/strict/needs-contract.json"))]
  }

  expect_failures = [output.summary]
}

run "presence_ref_skips_service" {
  command = plan

  variables {
    services = [merge(jsondecode(file("tests/fixtures/rendered/test/shop-api.json")), { presence_ref = "deploy-shop.app.url" })]
  }

  assert {
    condition     = output.summary.skipped_services == tolist(["shop-api"]) && output.summary.monitor_count == 0
    error_message = "a service whose presence reference is absent must be skipped"
  }
}
