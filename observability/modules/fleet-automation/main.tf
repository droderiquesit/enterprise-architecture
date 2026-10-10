# Datadog Fleet Automation: managed Agent upgrades inside a maintenance window (datadog_fleet_schedule, provider 4.25,
# Preview API; needs an application key with agent_upgrade_write + hosts_read). Remote upgrades also require the
# Agents to be installed with remote updates (fleet policy agent.remote_updates = true; modules/host-agents passes
# DD_REMOTE_UPDATES to the installer). Off by default: versions are pinned by the fleet policy (agent.version).
module "fleet" {
  source = "../fleet-policy"
  policy = var.fleet_policy
}

locals {
  sched   = try(module.fleet.agent.upgrade_schedule, {})
  enabled = var.enabled != null ? var.enabled : try(local.sched.enabled, false)
}

resource "datadog_fleet_schedule" "this" {
  count = local.enabled ? 1 : 0

  name   = var.name
  query  = var.host_query
  status = "active"
  rule = {
    days_of_week                = try(tolist(local.sched.days_of_week), ["Tue", "Wed", "Thu"])
    start_maintenance_window    = try(local.sched.start, "02:00")
    maintenance_window_duration = try(local.sched.duration_minutes, 120)
    timezone                    = try(local.sched.timezone, "UTC")
  }
  version_to_latest = try(local.sched.version_to_latest, 0)

  lifecycle {
    precondition {
      condition     = try(module.fleet.agent.remote_updates, false)
      error_message = "An upgrade schedule needs Agents installed with remote updates: set fleet policy agent.remote_updates = true."
    }
  }
}
