output "api_test_ids" {
  description = "Key -> public id of API tests."
  value       = { for k, t in datadog_synthetics_test.api : k => t.id }
}

output "browser_test_ids" {
  description = "Key -> public id of browser tests."
  value       = { for k, t in datadog_synthetics_test.browser : k => t.id }
}

output "monitor_ids" {
  description = "Key -> monitor id Datadog creates for each test (usable for monitor-based SLOs)."
  value       = merge({ for k, t in datadog_synthetics_test.api : k => t.monitor_id }, { for k, t in datadog_synthetics_test.browser : k => t.monitor_id })
}

output "skipped" {
  description = "Tests skipped because they need a private location and none was supplied."
  value       = sort([for k, t in var.tests : k if !contains(keys(local.runnable), k)])
}

output "statuses" {
  description = "Key -> live/paused."
  value       = merge({ for k, t in datadog_synthetics_test.api : k => t.status }, { for k, t in datadog_synthetics_test.browser : k => t.status })
}

output "locations" {
  description = "Key -> locations."
  value       = local.locations
}
