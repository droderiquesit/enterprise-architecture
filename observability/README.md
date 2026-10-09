# Observability package (Datadog monitoring-as-code for Azure)

Version: see `VERSION` (semantic versioning). Release notes: `CHANGELOG.md`. Upgrade notes: `UPGRADING.md`.

A portable, versioned package that onboards services running on Azure into Datadog from **one YAML
manifest per service**. It works against existing enterprise infrastructure: it never creates networks,
compute platforms, databases or applications, and it needs nothing outside this directory.

| What | Where |
|---|---|
| Terraform modules (monitoring content) | `modules/{onboarding,monitors,slos,dashboards,synthetics,service-catalog,rum,notification-routing,deployment-markers}` |
| Terraform modules (collection/transport) | `modules/{azure-integration,diagnostic-settings,telemetry-transport,fluent-bit,otel-collector,host-agents,kubernetes,instrumentation,dbm}` and `config/` (separate owner; see their READMEs) |
| Manifest / archetype / routing schemas | `schemas/*.v1.schema.json` |
| Monitoring archetypes | `archetypes/global-defaults.yaml`, `archetypes/platform/*.yaml`, `archetypes/profiles/*.yaml` |
| Tools | `tools/onboarding/{validate,render}.py`, `tools/verify/telemetry_verify.py`, `tools/markers/send_deployment_event.py`, `tools/release/package.sh` |
| Azure DevOps templates | `pipelines/templates/*.yml`, example `pipelines/azure-pipelines.consumer-example.yml` |
| Consumer example | `examples/existing-environment/` (vendors a release tarball, onboards existing App Service + AKS + PostgreSQL) |

Status vocabulary: everything here is **implemented** (static validation, `terraform test` with mock providers,
unit tests with recorded API responses). Nothing in this package has been deployed or verified against a live
Datadog organisation by these tests.

## 1. How it works

```
manifest (per service, per env)          archetypes (shipped, overridable)
        \                                   /
         tools/onboarding/render.py  (merge + templates, deterministic)
                      |
         rendered/<env>/<service>.json  (COMMITTED; CI runs `render --check`)
                      |
  Terraform root -> modules/onboarding  (resolves ${contract:...} refs, Azure scopes)
        |-> notification-routing  (route keys -> @handles per env)
        |-> monitors              (datadog_monitor)
        |-> slos                  (datadog_service_level_objective + "slo alert" burn-rate monitors)
        |-> synthetics            (API tests; browser journey; private locations)
        |-> dashboards            (datadog_dashboard_json: per service + application overview)
        |-> service-catalog       (datadog_software_catalog, entity v3)
        `-> datadog_downtime_schedule for declared quiet hours
```

### 1.1 Merge precedence (lowest -> highest)

1. `archetypes/global-defaults.yaml`
2. `archetypes/platform/<x>.yaml` whose `match.architectures` contains `spec.architecture`
3. `archetypes/platform/<x>.yaml` whose `match.resource_types` intersect the manifest's resource types (alphabetical)
4. `archetypes/profiles/<spec.telemetry.profile>.yaml`, preceded by its `extends` chain
5. the manifest: `metadata`, `spec`, `spec.monitors.params`, `spec.monitors.overrides["<key>"]`
6. after expansion: `spec.monitors.overrides["<key>@<role>"]`, then `spec.monitors.disabled` (globs)

Maps deep-merge. **Lists are replaced** unless the key ends with `+` (`tags+: [...]` appends). A monitor is removed by
`enabled: false` in any later layer or by `disabled`. `when:` conditions (`spec.telemetry.traces.enabled`,
`!spec.idle_behavior.scale_to_zero`, `spec.telemetry.logs.route!=none`) are evaluated after the full merge.

Template placeholders use `[[...]]` (never collides with Datadog `{{...}}` or HCL `${...}`). `render.py` expands
`[[service]] [[env]] [[team]] [[service_scope]] [[server_operation]] [[params.*]] [[critical]] [[warning]]`;
Terraform expands `[[resource.scope|name|role|id]]` after resolving resource ids.

### 1.2 Rendering and references (decision: commit rendered output)

* `render.py render` is run by the developer and the rendered JSON is **committed**. CI runs
  `render.py render ... --check` and fails on drift, so `terraform plan` needs **no Python**.
* Resource ids and endpoint URLs may be literals (existing environments) or references
  `${contract:<contract-name>.<dot.path>}` (environments that publish output contracts). References stay verbatim
  in the committed output and are resolved by `modules/onboarding` from `contract_references`
  (a flat map produced by `render.py references --contracts-dir <dir> --out references.auto.tfvars.json`).
* Unresolved **optional** (`required: false`) resources/endpoints are dropped with their monitors (listed in
  `summary.dropped_optional`); unresolved **required** ones fail the plan (output precondition).
* `spec.presence_ref` (optional): when set and absent from `contract_references`, the service is skipped (not deployed
  in this environment). `render.py render --contracts-dir` implements the same semantics in Python.

### 1.3 Monitor content (archetypes)

| Area | Monitors (key) | Signal |
|---|---|---|
| HTTP APIs (`profiles/http-api`) | `apm.error_rate`, `apm.http_5xx`, `apm.latency_p95`, `apm.no_traffic` | `trace.http.server.request.{hits,errors,hits.by_http_status}` + latency distribution |
| Consumers (`profiles/worker`) | `apm.consumer_error_rate` | `trace.servicebus.process.*` (OTel operation name logic v2) |
| Durable workflows (`profiles/durable-workflow`) | `workflow.failure_rate`, `workflow.duration_p95` | app metrics `<prefix>.workflow.completed{workflow,outcome}`, `<prefix>.workflow.duration` (ms, distribution) |
| Jobs (`profiles/job`) | `job.missed_run`, `job.errors` | logs |
| Frontends (`profiles/frontend`) | `rum.error_count`, `rum.lcp_p75` + browser synthetic | RUM |
| Telemetry pipeline (`profiles/telemetry-pipeline`) | `pipeline.canary_logs_missing`, `pipeline.fluentbit_*`, `pipeline.otel_*` | canary logs, `fluentbit_*_total`, `otelcol_*` |
| Platforms | `k8s.*` (AKS/ARO), `aca.*`, `appsvc.*`, `func.*`, `aci.*`, `logic.*`, `host.*` | kube-state-metrics core, Azure integration, Agent |
| Data/messaging resources | `sql.*`, `sqlmi.*`, `pg.*`, `mysql.*`, `cosmos.*`, `storage.*`, `redis.*`, `redis_classic.*`, `queue.*` (backlog, processing lag, dead letters), `eventhub.*` | Azure integration metrics |
| All services with logs | `logs.error_spike` | logs |

Every monitor message contains the summary, owner/team/tier, the resource, numbered troubleshooting steps and
`Runbook: <runbook_url>#<section>`; notification handles are appended per state (`is_alert`, `is_warning`,
`is_no_data`, `is_recovery`) by the monitors module from the routing file. Tags: `env, service, team, tier,
application, domain, managed_by:observability-package, monitor:<key>, severity:<sev>`.

Metric names were verified against Datadog documentation on 2026-10-09 (list and sources:
`tests/content/fixtures/verified-metrics.txt`; Azure tag names `subscription_id`, `resource_group`, `name`,
`server_name`, `statuscodecategory` from Datadog's recommended Azure monitors). Assumptions that could not be verified
from documentation are listed in section 9.

### 1.4 Missing telemetry vs. intentional idleness

* **Always-on** services (`idle_behavior.scale_to_zero: false`, the default except for Functions, Logic Apps,
  frontends, workers and jobs) get `apm.no_traffic` with `notify_no_data`: silence means the service or its pipeline
  is broken.
* **Scale-to-zero / event-driven** services never get trace no-data monitors. Their liveness comes from synthetic
  tests (endpoints), platform monitors (replicas, restarts), queue backlog/lag monitors and the job missed-run monitor.
* The **pipeline canary** (`pipeline.canary_logs_missing`) expects one heartbeat log per minute emitted by a
  Fluent Bit `dummy` input (`service:telemetry-canary`, attribute `canary:true`). It runs regardless of application
  traffic. `pipeline.fluentbit_not_reporting` and `pipeline.otel_not_reporting` watch the transport's own metrics.
  When the canary alerts, every application no-data alert in the same window is a pipeline problem.
* **Expected quiet hours** (`idle_behavior.expected_quiet_hours: {rrule, duration, timezone}`) create a recurring
  `datadog_downtime_schedule` that mutes only that service's monitors.

### 1.5 SLOs and burn-rate alerts

`availability` SLOs are metric-based (`hits - errors` / `hits`); `latency` SLOs are time-slice SLOs on the p95 of the
trace latency distribution (`threshold_ms`). Each SLO gets two `slo alert` monitors using
`burn_rate("<id>").over("<timeframe>").long_window(...).short_window(...) > N` with Datadog's recommended window
pairs (critical 1h/5m, warning 6h/30m; thresholds per timeframe in `global-defaults.yaml`). Thresholds above
90% of the maximum `1/(1-target)` are clamped with a warning.

## 2. Install (consumer)

Prerequisites: Terraform >= 1.14 (tested 1.16.5), DataDog/datadog provider `~> 4.25`, Python 3.11+ with
`pyyaml` and `jsonschema` (only for validate/render in CI), a Datadog API key + application key in Key Vault.

1. Pick a release: `observability-<version>.tar.gz` and its `.sha256` from the release feed.
2. Copy `examples/existing-environment/` into your repository; set `package.lock.json` `{version, sha256, url}` and
   run `./vendor.sh` (verifies the checksum, extracts to `.vendor/observability-<version>/`, which is git-ignored).
   Alternative without tarballs: `source = "git::https://dev.azure.com/<org>/<project>/_git/<repo>//observability/modules/<module>?ref=observability-v<version>"`.
3. Write one manifest per service (`schemas/onboarding-manifest.v1.schema.json`), a routing file per environment
   (`schemas/notification-routing.v1.schema.json`), then:
   ```
   python3 .vendor/observability-<v>/tools/onboarding/validate.py --manifests manifests --env prod --routing routing/prod.yaml --strict
   python3 .vendor/observability-<v>/tools/onboarding/render.py render --manifests manifests --env prod --out rendered/prod
   ```
   Commit `rendered/prod/*.json`.
4. `terraform init && terraform plan -out tfplan && terraform apply tfplan` (or the ADO templates in `pipelines/`).
   Provider credentials come from `DD_API_KEY` / `DD_APP_KEY`; never put keys in tfvars.

## 3. Configuration reference

* Manifest fields: see the schema descriptions. Monitor keys for `overrides`/`disabled` are listed in section 1.3
  (resource monitors are `<key>@<role>`). Thresholds are tuned through `spec.monitors.params` (names in each archetype's
  `params:` block) or per monitor through `overrides`.
* Your own archetypes: copy `archetypes/` into your repository, edit, and pass `--archetypes` to the tools (the merge
  rules are unchanged). Prefer manifest params/overrides to keep upgrades simple.
* `modules/onboarding` inputs: `services`, `routing`, `contract_references`, `synthetics {enabled, paused,
  private_location_id, response_time_ms}`, `dashboards {service_dashboards, overview, overview_title, journey}`,
  `service_catalog {enabled, system}`, `slos_enabled`, `extra_tags`, `strict_references`.
* Synthetics: public endpoints use managed locations (`aws:eu-central-1` default); private endpoints run only from
  `private_location_id` (else skipped and reported in `synthetics_skipped`). Tests are created **paused** unless
  `synthetics.paused = false` (set it in production).
* RUM: `modules/rum` outputs the application id and client token. The client token is the credential Datadog designs
  for browser apps (shipped to every visitor), so it is output non-sensitive; API/application keys never are.
* Deployment markers: the provider has no DORA/change-event resource (checked with the 4.25 schema), so pipelines run
  `tools/markers/send_deployment_event.py` (DORA API `POST /api/v2/dora/deployment`); `modules/deployment-markers`
  renders the commands.

## 4. Upgrade

Read `UPGRADING.md` for the target version. Procedure: bump `package.lock.json` (or the `?ref=` tag), run
`vendor.sh`, re-run `render.py render` (archetype changes show up as diffs in `rendered/`), review
`terraform plan` (the ADO plan template prints every destroy), apply. A minor/patch release never destroys a monitor
whose key still exists; Datadog objects are updated in place.

## 5. Rollback

Datadog objects are stateless configuration: re-vendor the previous version, re-render, plan and apply. Monitor ids
stay stable when keys are unchanged (for_each keys are `<service>/<monitor_key>`). Rendered output is committed,
so `git revert` of the onboarding commit plus apply restores the previous state exactly.

## 6. Removal

`terraform destroy` of a monitoring root removes **only Datadog objects** (monitors, SLOs, burn-rate alerts,
synthetic tests, dashboards, catalog entities, downtimes, optional webhooks). No Azure resource is created by the
monitoring modules, so none is removed. Collection modules (diagnostic settings, agents/extensions, Helm releases)
have their own removal notes; business data and monitored resources are never touched.

## 7. Versioning policy

Semantic versioning of the whole package (`VERSION`, tag `observability-v<version>`):

* **MAJOR**: breaking manifest/schema change, removed or renamed module input/output, renamed monitor key (would
  recreate monitors and lose history), changed rendered schema (`rendered-service/vN`).
* **MINOR**: new archetypes, monitors, optional inputs, new modules; default threshold changes are called out in the
  changelog.
* **PATCH**: fixes that do not change resources other than correcting content.

Releases are built with `tools/release/package.sh` (deterministic tarball + sha256; the build fails when a file
references paths outside the package, remote state, or a subscription id other than the all-zero placeholder or synthetic test ids of the form `xxxxxxxx-0000-0000-0000-000000000000`).

## 8. Pipelines

`pipelines/templates/`: `validate-onboarding.yml` (schema + semantic validation, rendered drift check),
`terraform-plan.yml` (OIDC, saved plan artifact, destroy summary), `terraform-apply.yml` (deployment job applying
the saved plan behind an ADO Environment), `telemetry-verify.yml` (bounded polling, evidence artifact),
`deployment-marker.yml`. Reference them from the package repository pinned to a release tag
(`resources.repositories` + `template: pipelines/templates/<t>.yml@obs`); a vendored tarball cannot provide templates
because ADO expands templates before any step runs.

## 9. Known limitations / assumptions to confirm in your organisation

* Service Bus entity tag: assumed `entityname` (Azure dimension `EntityName` lower-cased, same pattern as the verified
  `statuscodecategory`); override with `params.entity_tag`.
* Azure metric scoping uses `subscription_id`, `resource_group`, `name` (+ `server_name` for SQL databases) as in
  Datadog's recommended Azure monitors; the `name` tag of SQL databases is assumed to be the database name.
* Fluent Bit/OTel collector metric names assume the collector scrapes Fluent Bit's Prometheus endpoint without suffix
  trimming and exports its own telemetry with `without_type_suffix: true`, and that both carry an `env` tag.
* Worker operation name `servicebus.process` follows the OTel operation-name logic v2 mapping for messaging spans;
  set `spec.telemetry.traces.server_operation` if your instrumentation differs.
* RUM monitor syntax could not be validated with the Datadog validation API (organisation without RUM); log, metric,
  trace-metric and SLO burn-rate monitor shapes were validated (2026-10-09).
* Synthetic browser steps are limited to simple assertions (`assertPageContains`, `assertCurrentUrl`, ...).

## 10. Runbook sections

Monitor messages link to `<runbook_url>#<section>`: `error-rate`, `http-5xx`, `latency`, `missing-telemetry`,
`error-logs`, `consumer-errors`, `workflow-failures`, `workflow-duration`, `job-missed`, `job-errors`, `rum-errors`,
`rum-performance`, `replicas-unavailable`, `container-restarts`, `aca-5xx`, `aca-restarts`, `appservice-5xx`,
`appservice-latency`, `functions-5xx`, `host-cpu`, `aci-not-reporting`, `logicapp-failed`, `sql-cpu`,
`sql-connections`, `sql-deadlocks`, `sql-storage`, `postgres-down`, `postgres-cpu`, `postgres-connections`,
`postgres-storage`, `mysql-cpu`, `mysql-connections`, `mysql-storage`, `cosmos-ru`, `cosmos-availability`,
`storage-availability`, `storage-latency`, `queue-backlog`, `queue-lag`, `queue-dead-letter`, `queue-errors`,
`eventhub-throttled`, `redis-load`, `redis-memory`, `pipeline-canary`, `fluentbit-errors`, `fluentbit-dropped`,
`fluentbit-not-reporting`, `otel-export`, `otel-refused`, `otel-not-reporting`, `slo-burn-rate`, `slo-<name>`,
`synthetics`. Provide these anchors in each service runbook.

`metadata.runbook_url` is optional: when a manifest omits it, the archetype default `runbook_base_url`
(`archetypes/global-defaults.yaml`, placeholders `[[service]]`, `[[env]]`, `[[team]]`, `[[repository]]`) is used. The
shipped default is `[[repository]]?path=/docs/runbooks/alerts/[[service]].md` (Azure Repos file URL built from
`metadata.repository`); override it in your vendored global defaults (e.g. a wiki or a GitHub `blob/main/...` URL).
