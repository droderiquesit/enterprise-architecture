# modules/dashboards

`datadog_dashboard_json` from `templates/*.json.tftpl`: one dashboard per service (APM, RUM, durable workflows,
Azure resources by type, error logs, SLOs, monitor status, owner/runbook) and an application overview (journey,
databases/caches, queues/durable workflows, telemetry pipeline health). Output `rendered` exposes the JSON for review.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/dashboards.tftest.hcl`.
