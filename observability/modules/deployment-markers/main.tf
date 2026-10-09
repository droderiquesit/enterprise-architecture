# DataDog/datadog 4.25 has no resource for DORA deployment events or change events (checked with
# `tfschema list datadog_` on 2026-10-09: only datadog_deployment_gate exists, which gates deployments
# rather than recording them). Deployment markers are therefore sent by the pipeline with
# tools/markers/send_deployment_event.py (DORA API POST /api/v2/dora/deployment). This module only
# renders the exact commands, so pipelines and humans use one consistent definition.
locals {
  commands = {
    for name, s in var.services : name => join(" ", compact([
      "python3", var.script_path,
      "--site", var.datadog_site,
      "--service", name,
      "--env", s.env,
      s.team == null ? "" : "--team ${s.team}",
      s.repository_url == null ? "" : "--repository-url ${s.repository_url}",
      "--version \"$VERSION\" --commit-sha \"$COMMIT_SHA\" --started-at \"$DEPLOY_STARTED_AT\"",
    ]))
  }
}
