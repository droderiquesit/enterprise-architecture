# Adopting the observability package against existing infrastructure

The [`observability/`](../../observability/README.md) directory is a **portable, versioned package** (version in
[`observability/VERSION`](../../observability/VERSION), currently `4.0.0`). It configures existing Azure resources and
workloads to send telemetry to Datadog, through the most mature Datadog path each type supports, with one tag policy.

It never creates networks, compute platforms, databases or applications. It references nothing outside
`observability/`, which `tools/release/package.sh` and `observability/tests/portability` enforce. Monitors, SLOs and
dashboards are not part of it: they exist in your organisation and select on the tags.

This guide covers using a release in an organisation's own repository. The reference consumer is
[`observability/examples/existing-environment/`](../../observability/examples/existing-environment/README.md).
Per-resource collection paths: [datadog-fleet-collection.md](datadog-fleet-collection.md). Tags:
[datadog-tagging.md](datadog-tagging.md).

Status: implemented and tested offline. That covers mock providers, unit tests with recorded API responses, and
local docker tests of the ACI Agent sidecar and serverless-init (key from a mock DSV through `dsv-fetch`), Fluent Bit ->
Worker, the VRL, the Worker bootstrap, the APM gateway Agent and the OTel gateway, `helm template` of the Datadog chart
through the post-renderer, and the Linux VM Application installer. It has not been applied to a live Datadog organisation or Azure subscription.

## 1. Install

| Option | How | When |
|---|---|---|
| Vendored release tarball (recommended) | `package.lock.json` `{version, url, sha256}` -> `./vendor.sh` verifies the checksum, extracts to `./.vendor/observability-<version>/` (git-ignored) and checks that every module `source` uses that version | air-gapped or audited supply chain |
| Git reference | `source = "git::https://dev.azure.com/<org>/<project>/_git/<repo>//observability/modules/<module>?ref=observability-v<version>"` | consumers with read access to the source repository |
| Pipeline templates | `resources.repositories` pinned to the same tag, `template: pipelines/templates/<t>.yml@obs` | Azure DevOps consumers |

Prerequisites:

* Terraform >= 1.14.
* Providers: `DataDog/datadog ~> 4.25`, plus `azurerm ~> 5.9`, `azapi ~> 2.13` and `helm`/`kubernetes ~> 3.3` for
  the collection modules you use.
* Python 3.11+ with `pyyaml` and `jsonschema`, for validate and render in CI.
* Datadog API and application keys in Delinea DSV. The pipeline provides them as `DD_API_KEY` / `DD_APP_KEY`
  (`pipelines/templates/dsv-secrets.yml`), never in tfvars.

## 2. Adoption order

1. **Tag policy first.** Run `tools/tags/derive_from_monitors.py` against your organisation (read-only). It proposes
   the keys, aliases and value maps your existing monitors and SLOs depend on. Commit the reviewed policy
   ([datadog-tagging.md](datadog-tagging.md)).
2. **Fleet policy.** Review `config/fleet-policy.yaml`:
   - log pipeline (`observability_pipelines` | `fluent_bit_direct`);
   - APM mode (`datadog` | `otel`) and managed-runtime path;
   - profiling types;
   - Agent version and remote updates;
   - Worker sizing.

   Start with `apm.mode: otel` for environments whose applications are not yet built with the Datadog libraries.
3. **Onboard** the services (manifest v2, [service-onboarding-tutorial.md](service-onboarding-tutorial.md)).
4. **Connect:** Azure integration -> Observability Pipelines (pipeline + Worker) -> diagnostic settings / Activity Log
   -> Agents (AKS Helm, hosts) -> APM gateway -> DBM -> RUM.
5. **Hand over** the `instrumentation` output (tags, env, patches, `app_requirements`) to the application owners.
6. **Verify** with `tools/verify/telemetry_verify.py --expected-tags-dir rendered/<env>` and
   `tools/tags/check_coverage.py`.

## 3. Modules and required inputs

| Module | Purpose | Required inputs you supply |
|---|---|---|
| `tagging` | one tag set per workload / resource | `identity` (canonical values), optional `policy` |
| `fleet-inventory` | one collection plan per resource | `resources` (id, type, architecture, runtime, os_type, tags) |
| `azure-integration` | Datadog Azure integration (metrics + resource tags) | `mode`, `tenant_id`, `subscription_ids`, `metric_tag_filters` |
| `diagnostic-settings`, `azure-logs` | platform / control-plane logs to Event Hubs | `resources` (from `fleet-inventory` `diagnostic_targets`), `destination` |
| `observability-pipeline` | the `datadog_observability_pipeline` | `name`, `env`, `secret_refs` (DSV), `sources`, `eventhub_bootstrap`, `azure.scope_tags` |
| `telemetry-transport` | Event Hubs, Worker on Container Apps, APM gateway, OTel gateway (otel mode) | `name_prefix`, `resource_group`, `location`, `datadog {site, api_key_ref, env}`, `secrets`, `collector_identity`, `event_hub`, `container_apps` |
| `kubernetes` | Datadog Helm chart: node Agent, Cluster Agent, cluster-checks runners (logs to the Worker, SSI, profiling, DBM cluster checks; layered values + dsv-fetch post-renderer), optional Worker | `cluster_name`, `datadog`, `dsv`, `op_logs_url` or `op_worker`, `identity` |
| `host-agent-package` | Azure Compute Gallery + VM Applications (`datadog-agent-linux` / `-windows`: Agent installer + dsv-fetch release) | [README](../../observability/modules/host-agent-package/README.md) |
| `host-agent-policy` | Azure Policy DeployIfNotExists initiative enrolling hosts tagged `datadog:enabled` (VM Application + DSV-reader identity, least-privilege remediation role) | [README](../../observability/modules/host-agent-policy/README.md) |
| `host-agents` | wrapper over the two above (`mode = policy` default, `direct` = one gallery application assignment per VM) | `env`, `package`, `datadog`, `dsv`, `agent_identity` |
| `dbm` | DBM checks (AKS cluster checks by default, or an ACI Agent) | `databases`, `datadog`, `hosting`, `identity` |
| `instrumentation` | **integration hook** for application owners (no resources) | `service`, `runtime`, `architecture`, `telemetry` (the transport contract) |
| `rum` | RUM application (create or existing) + SDK config | `applications` |
| `fleet-automation` | optional Agent upgrade window | `name`, `host_query` |

## 4. Integration hooks for application owners

The package publishes; it does not apply. `modules/instrumentation` outputs:

* `env` and `secret_env` (`dsv://` references);
* `app_settings`, `container_app_patch`, `k8s_patch` or `aci_sidecar`;
* `tags`, `azure_tags`, `k8s_labels`, `k8s_annotations`;
* `apm` (mode, method, readiness) and `profiling` (enabled or the reason it is off);
* `log_collector` and `app_requirements`.

Application requirements in `apm.mode = datadog`:

* The image contains the Datadog library: `dd-trace-dotnet` at `/opt/datadog`, or `Datadog.Trace.Bundle` on App
  Service; `ddtrace` for Python. On AKS and Linux VMs, SSI injects it.
* The app reads `TELEMETRY_SDK` and never starts the OpenTelemetry SDK next to the Datadog tracer.
* Custom metrics go to DogStatsD where an Agent runs next to the process.

Fault injection is explicitly disabled in the existing-environment example.

Exactly one collector per signal (ADR-0001 section 10). The rules are in
[`observability/modules/README-transport.md`](../../observability/modules/README-transport.md) section 4.

## 5. Upgrade

1. Read `UPGRADING.md` and `CHANGELOG.md` of the target version. For **2.x -> 3.0.0**, decide first where your
   existing monitors and SLOs go (keep them with `extras/content` or hand them over). For **3.x -> 4.0.0**, plan the
   move to one collector per architecture (VM / VMSS hosts from run command to Azure Policy + VM Applications, Fluent
   Bit sidecars to serverless-init / the ACI Agent sidecar, the Go `dsv-fetch` 2.0.0 image and release zip) - the
   upgrade notes walk through both.
2. Bump `package.lock.json` (or the `?ref=` tag) **and** the pipeline templates' repository ref to the same version.
3. `./vendor.sh --update-sources`, then re-render every environment.
4. `terraform plan -out tfplan`. The plan template prints `DESTROY: [...]`. It must list no monitored infrastructure.
   Apply the saved plan.

## 6. Rollback

Re-vendor the previous version, re-render, plan and apply. The collection modules roll back like any Terraform
change: previous Helm values, VM Application version (`package_version`), Container App revisions, pipeline definition. The Worker keeps its
disk buffers across revisions only with `buffer_storage = azure_files` or on AKS (PVCs).

## 7. Removal (infrastructure and data preserved)

* Destroying the collection modules removes only what they created:
  * diagnostic settings (export stops; the resource and its data are untouched);
  * the `datadog_integration_azure` object;
  * the pipeline definition and the RUM application;
  * Helm releases, the host Agent policy assignment and gallery (Agents already installed stay until the VM
    Application is removed from the host model);
  * transport Container Apps;
  * the Event Hubs namespace, only with `event_hub.mode = create`. Unconsumed events in it are lost.
* Owners must revert the application instrumentation in their deployments.
* Telemetry already ingested follows the Datadog organisation's retention; destroy deletes no data.
