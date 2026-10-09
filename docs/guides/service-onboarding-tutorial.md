# Service onboarding tutorial (one manifest per service)

This tutorial onboards a service into Datadog with the observability package: one YAML manifest validated against
[`observability/schemas/onboarding-manifest.v1.schema.json`](../../observability/schemas/onboarding-manifest.v1.schema.json),
merged with the shipped archetypes, rendered to committed JSON and applied by Terraform. Reference documentation:
[`observability/README.md`](../../observability/README.md) sections 1-3.

The commands below were run against the worked example in this repository (validation and rendering only; no
Datadog organisation was available, so nothing was applied).

## 1. Write the manifest

Worked example: [`examples/onboarding/invoices-api.yaml`](examples/onboarding/invoices-api.yaml) - an existing .NET API on
Azure Container Apps with its own Azure SQL database (literal resource IDs; it is not part of the lab onboarding set).

```yaml
apiVersion: observability/v1
kind: ServiceOnboarding
metadata:
  service: invoices-api            # becomes DD_SERVICE / service tag
  team: orders                     # required
  owner: orders@example.com        # required
  runbook_url: https://runbooks.example.com/billing/invoices-api   # required; monitors link <url>#<section>
  env: dev                         # required (string or list)
  tier: high                       # critical | high | medium | low
  domain: billing
  application: enterprise-hello
spec:
  architecture: aca                # aks | aca | aci | appservice | functions | vm | vmss | logicapp | batch | swa | sfmc | aro | external
  runtime: dotnet
  telemetry:
    profile: http-api              # archetypes/profiles/<profile>.yaml
    logs: {route: sidecar}         # daemonset | sidecar | eventhub | host | none
    dbm: {enabled: true, engine: sqlserver}
  resources:                       # literal ARM ids or ${contract:<contract>.<path>} references
    - {id: /subscriptions/.../containerApps/ca-invoices-api-dev, type: Microsoft.App/containerApps, role: app}
    - {id: /subscriptions/.../servers/sql-billing-dev/databases/invoices, type: Microsoft.Sql/servers/databases, role: invoices-db}
  endpoints:
    - {name: internal, url: https://ca-invoices-api-dev.internal..., visibility: private, health_path: /readyz}
  slos:
    - {name: availability, type: availability, target: 99.5, timeframe: 30d}
    - {name: latency, type: latency, target: 99.0, timeframe: 30d, threshold_ms: 500}
  notifications:                   # route keys from the routing file, never raw @handles
    default: [team-orders]
    critical: [team-orders, oncall]
```

Inside this lab, resource IDs and URLs come from contracts instead of literals, for example
`${contract:deploy-core-aca.apps.hello-orders-api.id}` and `presence_ref: deploy-core-aca.apps.hello-orders-api.url`
(skip the service when it is not deployed) - see [`observability/onboarding/dev/hello-orders-api.yaml`](../../observability/onboarding/dev/hello-orders-api.yaml).

Tuning without forking archetypes: `spec.monitors.params` (named thresholds), `spec.monitors.overrides["<key>"]` or
`["<key>@<role>"]`, `spec.monitors.disabled` (globs), `spec.idle_behavior` (`scale_to_zero`, `expected_quiet_hours`).

## 2. Validate and render

```bash
python3 observability/tools/onboarding/validate.py --manifests docs/guides/examples/onboarding --env dev \
  --routing observability/onboarding/routing/dev.yaml --strict
# VALID (0 errors, 0 warnings)

python3 observability/tools/onboarding/render.py render --manifests docs/guides/examples/onboarding --env dev --out /tmp/rendered
# rendered 1 services for env 'dev'
```

For the lab, put the manifest in `observability/onboarding/<env>/`, render into `observability/onboarding/rendered/<env>/`
and **commit the rendered JSON**; CI runs `render ... --check` and fails on drift, so `terraform plan` needs no Python.

## 3. What gets created

For the worked example the merge of `global-defaults` + `platform/aca` + `platform/database-sql` + `profiles/http-api`
+ the manifest renders these monitor keys:

| Key | Source archetype | Signal |
|---|---|---|
| `apm.error_rate`, `apm.http_5xx`, `apm.latency_p95`, `apm.no_traffic` | profiles/http-api | `trace.http.server.request.*` (no-data guard because the service is always-on) |
| `logs.error_spike` | global-defaults | error log volume |
| `aca.http_5xx_ratio@app`, `aca.restarts@app` | platform/aca | Azure integration metrics of the container app |
| `sql.cpu@invoices-db`, `sql.connection_failures@invoices-db`, `sql.deadlocks@invoices-db`, `sql.storage@invoices-db` | platform/database-sql | Azure integration metrics of the database |

Plus, from `modules/onboarding` when Terraform applies the rendered file:

* two SLOs (`availability` metric-based, `latency` time-slice on p95) and two burn-rate `slo alert` monitors each
  (critical 1h/5m, warning 6h/30m);
* a synthetic API test per endpoint - private endpoints only from a configured private location (otherwise skipped
  and listed in `synthetics_skipped`); tests are created **paused** unless `synthetics.paused = false`;
* a service dashboard (and the application overview when enabled), a Software Catalog entity (`component_of`
  system), a `datadog_downtime_schedule` for declared quiet hours;
* tags `env, service, team, tier, application, domain, managed_by:observability-package, monitor:<key>, severity:<sev>`
  on every monitor; notification handles appended per state from the routing file.

Nothing in Azure is created by the monitoring modules. DBM (`telemetry.dbm`) is configured by the collection module
`modules/dbm` (lab: `obs-dbm`), not by onboarding.

## 4. Apply

* **Lab**: commit the rendered file; `obs-monitoring` lists `observability/onboarding/**` in its `inputs`, so change
  detection selects it and the pipeline plans/applies it after the selected deployments.
* **Elsewhere**: a consumer root that calls `modules/onboarding` (template:
  [`observability/examples/existing-environment/`](../../observability/examples/existing-environment/README.md)) with
  `DD_API_KEY` / `DD_APP_KEY` in the environment: `terraform init && terraform plan -out tfplan && terraform apply tfplan`.

## 5. Instrument the application (owner's side)

The package never changes application settings. The application owner applies the integration hook of
`modules/instrumentation` (outputs `env`, `secret_env`, `app_settings`, `container_app_patch`, `k8s_patch`,
`aci_sidecar`, `log_route`, `otlp_target`, `datadog_tags`): `DD_ENV/DD_SERVICE/DD_VERSION`, `OTEL_SERVICE_NAME`,
`OTEL_RESOURCE_ATTRIBUTES` (team, domain, tier, application, owner, region, `cloud.provider=azure`, `cloud.platform`),
`OTEL_EXPORTER_OTLP_ENDPOINT/PROTOCOL`, `OTEL_TRACES_SAMPLER=parentbased_traceidratio`, `OTEL_LOGS_EXPORTER=none`, and
for the sidecar route the Fluent Bit sidecar with `LOG_FILE_PATH`. In this lab the deployment roots do this through
`applications/deployments/modules/app-env`.

## 6. Verify

After traffic flows, `observability/tools/verify/telemetry_verify.py` checks a journey end to end (RUM -> trace,
spans of every journey service plus a database span, pipeline logs correlated to the trace, no duplicate log lines,
required tags, infra metrics). It has only been exercised against recorded API responses in unit tests.
