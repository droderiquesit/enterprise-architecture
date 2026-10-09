# Adopting the observability package against existing infrastructure

The [`observability/`](../../observability/README.md) directory is a **portable, versioned package** (version in
[`observability/VERSION`](../../observability/VERSION), currently `1.0.0`). It never creates networks, compute platforms,
databases or applications, and it references nothing outside `observability/` (enforced by `tools/release/package.sh`
and `observability/tests/portability`). This guide covers using a release in an organisation's own repository against
existing Azure resources. The reference consumer is
[`observability/examples/existing-environment/`](../../observability/examples/existing-environment/README.md).

Status: implemented and statically tested (mock providers, unit tests with recorded API responses, local docker tests
of the Fluent Bit / OTel configurations). Not yet applied to a live Datadog organisation or Azure subscription.

## 1. Install

| Option | How | When |
|---|---|---|
| Vendored release tarball (recommended) | `package.lock.json` `{version, url, sha256}` -> `./vendor.sh` verifies the checksum, extracts to `./.vendor/observability-<version>/` (git-ignored) and checks that every module `source` uses that version | air-gapped or audited supply chain |
| Git reference | `source = "git::https://dev.azure.com/<org>/<project>/_git/<repo>//observability/modules/<module>?ref=observability-v<version>"` | consumers with read access to the source repository |
| Pipeline templates | `resources.repositories` pinned to the same tag, `template: pipelines/templates/<t>.yml@obs` (a tarball cannot provide templates: ADO expands templates before steps run) | Azure DevOps consumers |

Release build: `observability/tools/release/package.sh` (deterministic tarball + `.sha256`; fails when a file references
paths outside the package, remote state, or a non-placeholder subscription ID).

Prerequisites: Terraform >= 1.14, `DataDog/datadog ~> 4.25` (+ `azurerm ~> 5.9`, `azapi ~> 2.13`, `helm`/`kubernetes ~> 3.3`
for the collection modules you use), Python 3.11+ with `pyyaml` + `jsonschema` for validate/render in CI, Datadog API +
application keys in your secret store (the lab: Delinea DSV, resolved per step with `tools/secrets/fetch.py`), provided to
Terraform as `DD_API_KEY` / `DD_APP_KEY` (never in tfvars).

## 2. Required inputs

| Module | Purpose | Required inputs you supply |
|---|---|---|
| `onboarding` | monitors, SLOs, synthetics, dashboards, catalog, downtimes | `services` (rendered JSON), `routing` (routing file), optional `contract_references`, `synthetics {enabled, paused, private_location_id}` |
| `azure-integration` | Datadog Azure integration | `mode` = `app_registration` (existing Entra app; Secretless Auth or `client_secret`) / `native` (Datadog native resource) / `none`, `tenant_id`, `subscription_ids`, `metric_tag_filters` |
| `diagnostic-settings` | platform/app log export to Event Hubs | `resources` (id, `app_log_route`, `platform_logs`), `destination` (Event Hub authorization rule + hub names); only categories the resource supports are enabled |
| `telemetry-transport` | Event Hubs + Fluent Bit aggregator + OTel gateway on Container Apps (internal ingress) | `name_prefix`, existing `resource_group`, `location`, `datadog {site, api_key_secret_id (versionless KV id), env}`, `collector_identity`, `key_vault`, `event_hub {mode = create / existing / none}`, `container_apps` (existing environment), `aggregator`, `gateway` |
| `kubernetes` | Datadog Agent + Cluster Agent + Fluent Bit DaemonSet via Helm | `cluster_name`, `datadog`, `api_key` (or write-only `api_key_wo`), `namespaces`, `fluent_bit`, optional `cluster_checks` (DBM) |
| `host-agents` | Datadog Agent VM extension + Fluent Bit setup on VMs / scale sets | `hosts`, `datadog`, `api_key`, `fluent_bit_version` |
| `dbm` | DBM check configuration (and optional ACI agent host) | `databases` (engine, host, deployment type, auth / password reference), `hosting` |
| `instrumentation` | **integration hook** for application owners (no resources) | `service`, `runtime`, `architecture`, `telemetry` (OTLP targets, site, secret ids) |
| `rum` | RUM applications | `applications` |

## 3. Integration hooks for application owners

The package publishes, it does not apply: `modules/instrumentation` outputs `env`, `secret_env` (name -> secret
reference; the lab uses Delinea DSV `dsv://` references), `app_settings` (App Service / Functions, references resolved at
start-up), `container_app_patch`
(+ JSON), `k8s_patch` (+ object), `aci_sidecar`, `log_route`, `otlp_target`, `datadog_tags`. The example root exposes
them as `terraform output instrumentation`; hand that to the application teams. Their deployment applies the env vars
or patch (in this lab: `applications/deployments/modules/app-env`). Fault injection is explicitly disabled in the
existing-environment example (`fault_injection_enabled` defaults to `false` and a validation rejects `true`).

Exactly one collector per signal (ADR-0001 section 10 also applies to consumers): when Fluent Bit collects container
logs, keep Agent container log collection off; the OTel gateway drops OTLP logs.

## 4. Upgrade

1. Read `UPGRADING.md` and `CHANGELOG.md` of the target version.
2. Bump `package.lock.json` (or the `?ref=` tag) **and** the pipeline templates' repository ref to the same version.
3. `./vendor.sh --update-sources`, re-render every environment (`render.py render ... --out rendered/<env>`); the diff of
   `rendered/` is the exact change set of monitoring content.
4. `terraform plan -out tfplan`; the plan template prints `DESTROY: [...]`. A MINOR/PATCH release must destroy no
   monitored infrastructure (none is managed) and no monitor whose key still exists. Apply the saved plan.

Monitor keys (`<service>/<monitor_key>[@role]`) are public interface: renaming one is a MAJOR change (recreates the
monitor, loses history and mute state).

## 5. Rollback

Datadog objects are configuration: re-vendor the previous version, re-render, plan, apply. Because rendered output is
committed, `git revert` of the onboarding commit plus apply restores the previous state exactly; monitor IDs stay stable
when keys are unchanged. Collection modules roll back the same way (previous Helm chart values, previous extension
settings, previous Container App revision of the gateway/aggregator).

## 6. Removal (infrastructure and data preserved)

* `terraform destroy` of a monitoring root removes **only Datadog objects** (monitors, SLOs, burn-rate alerts,
  synthetic tests, dashboards, catalog entities, downtimes, optional webhooks).
* Destroying collection modules removes only what they created: diagnostic settings (export stops; the resource and
  its data are untouched), the `datadog_integration_azure` object (the Entra app and its role assignments are not managed
  there and stay), Helm releases and VM extensions (agents uninstalled), transport Container Apps and - only with
  `event_hub.mode = create` - the Event Hubs namespace it created (buffered, not yet consumed log events in it are lost).
* Application instrumentation applied by owners must be reverted in their deployments; without a collector the SDKs
  just fail to export.
* Telemetry already ingested follows the Datadog organisation's retention; destroy deletes no data.

Order: monitoring root first (so alerts do not fire on the removal), then diagnostic settings and agents, then transport.
