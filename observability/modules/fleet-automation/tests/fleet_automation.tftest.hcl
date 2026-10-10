mock_provider "datadog" {
  mock_resource "datadog_fleet_schedule" {
    defaults = { id = "sched-1" }
  }
}

variables {
  name       = "eh-dev-agent-upgrades"
  host_query = "env:dev AND managed_by:terraform"
}

run "off_by_default" {
  command = plan
  assert {
    condition     = length(datadog_fleet_schedule.this) == 0 && output.schedule_id == null
    error_message = "no schedule unless the policy enables it"
  }
}

run "schedule_from_policy" {
  command = apply
  variables {
    fleet_policy = {
      apiVersion = "observability/fleet-policy/v1"
      kind       = "FleetPolicy"
      agent = {
        remote_updates   = true
        upgrade_schedule = { enabled = true, days_of_week = ["Tue"], start = "03:30", duration_minutes = 90, timezone = "Europe/Stockholm", version_to_latest = 0 }
      }
    }
  }
  assert {
    condition     = datadog_fleet_schedule.this[0].rule.start_maintenance_window == "03:30" && datadog_fleet_schedule.this[0].rule.timezone == "Europe/Stockholm" && datadog_fleet_schedule.this[0].query == "env:dev AND managed_by:terraform"
    error_message = "maintenance window from the fleet policy"
  }
}

run "requires_remote_updates" {
  command = plan
  variables {
    enabled = true
  }
  expect_failures = [datadog_fleet_schedule.this]
}
