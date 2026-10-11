# Service onboarding and package adoption

How to connect a service to Datadog with the observability package: one YAML manifest per service
([`onboarding-manifest.v2`](../../observability/schemas/onboarding-manifest.v2.schema.json)) holds identity, tags,
resources and telemetry routing. It is validated against the [tag policy](datadog-tagging.md), rendered to committed
JSON and consumed by the collection modules and the application's instrumentation hook. Monitors, SLOs and dashboards
are not created by the package; they select on the tags the manifest makes consistent.

Package reference (install, upgrade, rollback, removal, versioning): [`observability/README.md`](../../observability/README.md)
and [`UPGRADING.md`](../../observability/UPGRADING.md). Reference consumer outside this lab:
[`observability/examples/existing-environment/`](../../observability/examples/existing-environment/README.md).
Validation and rendering below were run in this repository; nothing was applied to a Datadog organisation.

## Adoption order (organisation-level use of a release)

1. **Tag policy first:** derive it read-only from your existing monitors ([datadog-tagging.md](datadog-tagging.md#2-adopt-it-from-your-existing-monitors)).
2. **Fleet policy:** review `config/fleet-policy.yaml` (log pipeline, APM mode and managed-runtime path, profiling,
   Agent version, Worker sizing). Start with `apm.mode: otel` where applications do not yet ship the Datadog libraries.
3. **Onboard** the services (below).
4. **Connect:** Azure integration -> Observability Pipelines (pipeline + Worker) -> diagnostic settings / Activity Log
   -> Agents (AKS Helm, hosts) -> APM gateway -> DBM -> RUM.
5. **Hand over** the `instrumentation` output to the application owners (section 5).
6. **Verify** (section 6).

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
    logs: {route: sidecar}         # optional; default from the fleet policy per architecture
    dbm: {enabled: true, engine: sqlserver}
    # apm: {mode: otel}            # optional per-service override (datadog | otel | none)
    # profiling: {enabled: false}  # optional per-service override
  resources:                       # literal ARM ids or ${contract:<contract>.<path>} references
    - {id: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing-dev/providers/Microsoft.App/containerApps/ca-invoices-api-dev, type: Microsoft.App/containerApps, role: app}
    - {id: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing-dev/providers/Microsoft.Sql/servers/sql-billing-dev/databases/invoices, type: Microsoft.Sql/servers/databases, role: invoices-db}
```

Inside this lab, resource ids come from contracts, e.g. `${contract:deploy-core-aca.apps.hello-orders-api.id}` with
`presence_ref: deploy-core-aca.apps.hello-orders-api.url` (skip the service when it is not deployed); see
[`observability/onboarding/dev/hello-orders-api.yaml`](../../observability/onboarding/dev/hello-orders-api.yaml).

A 2.x (v1) manifest converts with `python3 observability/tools/onboarding/migrate_v1.py --in <dir> --out <dir> --region <region>`
(keeps identity, resources and routing; drops the monitoring sections). Example output:
[`examples/onboarding/invoices-api.yaml`](examples/onboarding/invoices-api.yaml).

## 2. Validate and render

```bash
python3 observability/tools/onboarding/validate.py --manifests manifests/dev --env dev --strict
# VALID (0 errors, 0 warnings, 0 notices)
python3 observability/tools/onboarding/render.py render --manifests manifests/dev --env dev --out rendered/dev
# rendered 1 services for env 'dev'
```

Validation fails on a missing required tag-policy key, a disallowed value or a non-ARM resource id; monitoring
sections (`monitors`, `slos`, ...) only produce a notice. In the lab, manifests live in `observability/onboarding/<env>/`,
renders in `observability/onboarding/rendered/<env>/`; **commit the rendered JSON** (CI runs `render ... --check`).

## 3. What the rendered service carries

| Field | Example | Used by |
|---|---|---|
| `tags` | `env:dev, service:invoices-api, team:orders, owner:orders_example.com, ...` (Datadog-normalised) | instrumentation (`DD_TAGS`), pipeline / gateway defaults, telemetry_verify |
| `azure_tags` | same keys, Azure values (`owner: orders@example.com`) | the deployment root's Azure resource tags |
| `resources[*].tags` | per resource | `modules/fleet-inventory` -> resource-scope tags of platform logs, diagnostic targets, DBM candidates |
| `telemetry` | `logs_route: sidecar`, `apm_mode: policy`, `dbm` | instrumentation, diagnostic settings, DBM |

`version` is set at deploy time (`DD_VERSION`), not in the manifest.

## 4. Connect the resources (platform side)

The rendered resources feed `modules/fleet-inventory`, whose outputs drive `modules/diagnostic-settings` and give the
pipeline its resource-scope tags; `modules/dbm` configures DBM for `telemetry.dbm`. In the lab this happens in the
`obs-*` roots.

## 5. Instrument the application (owner's side)

The package never changes application settings. The owner applies the outputs of `modules/instrumentation`: `env` and
`secret_env` (DSV references), one of `app_settings` / `container_app_patch` / `k8s_patch` / `aci_sidecar`, the tag
outputs, and `app_requirements` (which Datadog library the image must contain). The variables it sets per mode are
the [APM library contract](datadog-fleet-collection.md#3-apm-library-contract-apmmode--datadog); the log collector
(serverless-init sidecar on Container Apps, Agent sidecar on ACI) follows the fleet policy. In this lab the deployment
roots apply the hook through `applications/deployments/modules/app-env`.

## 6. Verify

Once traffic flows, `observability/tools/verify/telemetry_verify.py --expected-tags-dir rendered/<env>` checks a journey
end to end (RUM -> trace link, spans of every journey service plus a database span, correlated logs without
duplicates, the tag-policy values, the pipeline tag); `observability/tools/tags/check_coverage.py` reports which
monitored scopes miss which tags. Both have only been exercised against recorded API responses.
