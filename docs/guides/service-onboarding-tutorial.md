# Service onboarding tutorial (one manifest per service, package 4.0.0)

This tutorial connects a service to Datadog with the observability package. You write one YAML manifest
([`onboarding-manifest.v2`](../../observability/schemas/onboarding-manifest.v2.schema.json)) that holds the identity,
tags, resources and telemetry routing. The manifest is validated against the
[tag policy](datadog-tagging.md), rendered to committed JSON, and consumed by the collection modules and the
application's instrumentation hook.

Monitors, SLOs and dashboards are not created by the package. They already exist in your organisation and select on
the tags this manifest makes consistent. Reference: [`observability/README.md`](../../observability/README.md).

The commands below were run in this repository (validation and rendering only; no Datadog organisation was
available, so nothing was applied).

## 1. Write the manifest

Example: an existing .NET API on Azure Container Apps with its own Azure SQL database (literal resource ids).

```yaml
apiVersion: observability/v2
kind: ServiceOnboarding
metadata:
  service: invoices-api            # DD_SERVICE / service tag
  team: orders                     # required tag-policy keys: team, owner, application, domain, tier, region
  owner: orders@example.com
  application: enterprise-hello
  domain: billing
  tier: high                       # critical | high | medium | low | infrastructure
  region: swedencentral
  env: dev                         # string or list; value_map normalises e.g. development -> dev
spec:
  architecture: aca                # aks | aca | aci | appservice | functions | vm | vmss | logicapp | batch | swa
  runtime: dotnet
  telemetry:
    logs: {route: sidecar}         # optional; default from the fleet policy per architecture (aca: the serverless-init sidecar)
    dbm: {enabled: true, engine: sqlserver}
    # apm: {mode: otel}            # optional per-service override of the fleet policy (datadog | otel | none)
    # profiling: {enabled: false}  # optional per-service override
  resources:                       # literal ARM ids or ${contract:<contract>.<path>} references
    - {id: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing-dev/providers/Microsoft.App/containerApps/ca-invoices-api-dev, type: Microsoft.App/containerApps, role: app}
    - {id: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing-dev/providers/Microsoft.Sql/servers/sql-billing-dev/databases/invoices, type: Microsoft.Sql/servers/databases, role: invoices-db}
```

Inside this lab, resource ids come from contracts instead of literals, for example
`${contract:deploy-core-aca.apps.hello-orders-api.id}` together with
`presence_ref: deploy-core-aca.apps.hello-orders-api.url` (skip the service when it is not deployed). See
[`observability/onboarding/dev/hello-orders-api.yaml`](../../observability/onboarding/dev/hello-orders-api.yaml).

Coming from a 2.x (v1) manifest: `python3 observability/tools/onboarding/migrate_v1.py --in <dir> --out <dir> --region <region>`
converts it. It keeps identity, resources and routing, and drops the monitoring sections. The worked example
[`examples/onboarding/invoices-api.yaml`](examples/onboarding/invoices-api.yaml) is the unedited output of
`migrate_v1.py --region swedencentral` for the 2.x (v1) invoices-api manifest: the manifest above plus the optional metadata (display name, repository, ...).

## 2. Validate and render

```bash
python3 observability/tools/onboarding/validate.py --manifests manifests/dev --env dev --strict
# VALID (0 errors, 0 warnings, 0 notices)

python3 observability/tools/onboarding/render.py render --manifests manifests/dev --env dev --out rendered/dev
# rendered 1 services for env 'dev'
```

Validation fails when a required tag-policy key is missing, a value is not allowed, or a resource id is not an ARM
id. Monitoring sections (`monitors`, `slos`, `notifications`, ...) only produce a notice: the core package ignores
them.

For the lab, put the manifest in `observability/onboarding/<env>/`, render into
`observability/onboarding/rendered/<env>/` and **commit the rendered JSON**. CI runs `render ... --check`.

## 3. What the rendered service carries

| Field | Example | Used by |
|---|---|---|
| `tags` | `env:dev, service:invoices-api, team:orders, owner:orders_example.com, application:enterprise-hello, domain:billing, tier:high, region:swedencentral, managed_by:terraform` (Datadog-normalised) | instrumentation (`DD_TAGS`), Observability Pipelines / OTel gateway defaults, telemetry_verify expected tags |
| `azure_tags` | the same keys, Azure values (`owner: orders@example.com`) | the deployment root's Azure resource tags (imported by the Datadog Azure integration) |
| `resources[*].tags` | per resource | `modules/fleet-inventory` -> resource-scope tags of platform logs, diagnostic targets, DBM candidates |
| `telemetry` | `logs_route: sidecar`, `apm_mode: policy`, `dbm` | instrumentation, diagnostic settings, DBM |

`version` is a deploy-time value. The deployment sets it (`DD_VERSION`); it is not part of the manifest.

## 4. Connect the resources (platform side)

* The rendered resources feed `modules/fleet-inventory`. Its outputs drive `modules/diagnostic-settings` (platform
  logs, and app logs for the `eventhub` route) and give the Observability Pipelines pipeline the resource-scope tags.
* `modules/dbm` configures Database Monitoring for `telemetry.dbm`.
* In the lab this happens in the `obs-*` roots; elsewhere see
  [`observability/examples/existing-environment/`](../../observability/examples/existing-environment/README.md).

## 5. Instrument the application (owner's side)

The package never changes application settings. The owner applies the hook of `modules/instrumentation`:

* `env` and `secret_env` (DSV references);
* `app_settings`, `container_app_patch`, `k8s_patch` or `aci_sidecar`;
* `app_requirements`: which Datadog library the image must contain.

With the default `apm.mode = datadog` the hook sets these variables:

* `TELEMETRY_SDK=datadog` and `DD_TRACE_OTEL_ENABLED=true`;
* `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, and `DD_TAGS` with the extra policy keys;
* `DD_LOGS_INJECTION=true` and `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED=true`;
* the profiler settings;
* the trace / DogStatsD target: on AKS `DD_AGENT_HOST` = node IP; on Container Apps and ACI the local sidecar
  (`localhost:8126` / `udp://localhost:8125`, no `DD_TRACE_AGENT_URL`); `DD_TRACE_AGENT_URL` = the in-VNet APM gateway
  only on the `agent_gateway` path (Container Apps jobs, App Service workloads that opt into `apm.mode = datadog`).

It sets **no** `OTEL_*` variable. With `apm.mode = otel` (the App Service and Functions default) the hook sets the
OpenTelemetry variables instead. The log collector follows the fleet policy: on Container Apps `container_app_patch`
adds the Datadog **serverless-init** sidecar and on ACI `aci_sidecar` the **Datadog Agent** sidecar, both tailing
`LOG_FILE_PATH` and shipping to the Observability Pipelines Worker; each reads the Datadog API key from DSV with the
`dsv-fetch` binary. A Fluent Bit sidecar is added only with `log_pipeline = fluent_bit_direct`. In this lab the
deployment roots apply the hook through `applications/deployments/modules/app-env`.

## 6. Verify

Once traffic flows, `observability/tools/verify/telemetry_verify.py --expected-tags-dir rendered/dev` checks a journey
end to end:

* the RUM -> trace link;
* spans of every journey service plus a database span;
* logs correlated to the trace, with no duplicates;
* the tag-policy tags with their rendered values;
* the pipeline tag of the fleet policy.

`observability/tools/tags/check_coverage.py` reports which monitored scopes miss which tags. Both tools have only been
exercised against recorded API responses.
