# modules/fleet-automation

Optional managed Agent upgrades: a `datadog_fleet_schedule` (provider 4.25, Preview API) built from fleet policy
`agent.upgrade_schedule` (`days_of_week`, `start`, `duration_minutes`, `timezone`, `version_to_latest`). The
`host_query` selects the Agents with tag-policy tags, for example `env:prod AND managed_by:terraform`.

It is off by default: Agent versions are pinned by the policy (`agent.version`). The schedule requires
`agent.remote_updates = true` (precondition). Hosts must be installed with remote updates; `modules/host-agents` passes
`DD_REMOTE_UPDATES` to the installer. The application key needs `agent_upgrade_write` and `hosts_read`.
Remote Configuration (`agent.remote_configuration`, on by default) is set on every Agent the package configures.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/fleet_automation.tftest.hcl`.
