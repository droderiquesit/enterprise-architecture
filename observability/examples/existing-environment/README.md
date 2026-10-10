# Example: connect an EXISTING environment to Datadog with a versioned package release (3.0.0)

Standalone consumer root. It needs nothing from the source repository except the released tarball. It connects
existing resources to Datadog with the package tag policy. It creates no monitors, SLOs or dashboards: those already
exist in your organisation and select on the tags this root makes consistent.

| Existing resource (ids supplied in manifests) | What this root configures |
|---|---|
| App Service `app-orders-web-prod` (`manifests/prod/orders-web.yaml`) | Diagnostic settings (app logs on the eventhub route + platform logs) -> Event Hubs -> Observability Pipelines; Datadog tracer settings (APM gateway, profiling) for the owners; RUM application (`modules/rum`, create or existing) |
| AKS workload `orders-api` on `aks-prod-weu` | Datadog Agent + Cluster Agent: pod logs -> OP Worker, Single Step Instrumentation of `orders` (profiling `auto`), UST labels; Kubernetes patch for the owners |
| PostgreSQL flexible server `psql-orders-prod` | Platform logs; Database Monitoring as cluster checks (`modules/dbm`, DSV password reference) |
| Event Hubs `evhns-obs-prod` | Read by the Observability Pipelines Worker (Kafka source; listen connection string from a DSV-synced Secret) |
| Datadog Azure integration (`modules/azure-integration`, existing Entra app, secretless) | Azure Monitor metrics + resource tags for every resource |
| Datadog Observability Pipelines (`modules/observability-pipeline`) | One pipeline for the environment: tag policy defaults, Azure log shaping, resource-scope tags from the fleet inventory, redaction, disk-buffered Datadog Logs destination; the Worker runs on the existing AKS cluster (`modules/kubernetes` `op_worker`, StatefulSet with one persistent volume per replica) |

One input describes the fleet: the rendered manifests. `modules/fleet-inventory` derives the single authoritative
collector per resource and signal (`terraform output collection_matrix`). No sample applications, no networks,
platforms or databases are created. Fault injection is disabled and validated.

## Steps

1. Pin the release in `package.lock.json` (`version`, `url`, `sha256` from the release `.sha256` file).
2. `./vendor.sh` downloads the release, verifies the sha256, extracts it to `./.vendor/observability-<version>/`
   (git-ignored) and checks that every module `source` uses that version.
   Alternative without vendoring: `source = "git::https://dev.azure.com/<org>/<project>/_git/<repo>//observability/modules/<module>?ref=observability-v3.0.0"`.
3. Edit `manifests/prod/*.yaml` (manifest v2: identity + tags + resources; resource ids are used **verbatim**), then
   `python3 .vendor/observability-3.0.0/tools/onboarding/validate.py --manifests manifests/prod --env prod --strict`
   and `python3 .vendor/observability-3.0.0/tools/onboarding/render.py render --manifests manifests/prod --env prod --out rendered/prod`.
   Commit `rendered/prod`.
4. Secrets: the Delinea dsv-k8s syncer keeps the Secrets `observability-pipelines/datadog-api-key` (key `api-key`) and
   `observability-pipelines/eventhub-listen` (key `connection-string`). The Agents resolve `ENC[dsv://...]` themselves.
   No secret value passes through Terraform.
5. Run `terraform init` (backend: your partial config), then `terraform plan -out tfplan`, then
   `terraform apply tfplan`, with `DD_API_KEY`/`DD_APP_KEY` in the environment (from DSV). Pipelines: use
   `pipelines/azure-pipelines.consumer-example.yml` in the package.
6. Hand `terraform output instrumentation` to the application owners. It contains the tags, the App Service app
   settings or Kubernetes patch, the env vars, the Delinea DSV `dsv://` references and `app_requirements` (which
   Datadog library the image must contain). Hand `terraform output rum` to the frontend owners. This root never
   changes application settings.

Tests: `terraform test` (after `./vendor.sh`) runs plan-only checks with mocked providers.

## Upgrade

1. Set the new version and sha256 in `package.lock.json`.
2. Run `./vendor.sh --update-sources` (it rewrites the `./.vendor/observability-<old>/` module sources).
3. Re-render the manifests and run `terraform plan`.

A MINOR/PATCH upgrade updates objects in place. For 2.x -> 3.0.0 read the package `UPGRADING.md`
(`tools/onboarding/migrate_v1.py`, and `tools/tags/derive_from_monitors.py` before you adopt the tag policy).

## Removal safety

* `terraform destroy` of this root removes only what it created:
  * the Observability Pipelines pipeline and the RUM application;
  * the Datadog Agent / Worker Helm releases and their namespaces;
  * the DBM cluster checks;
  * the diagnostic settings (log export stops; the resources and their data are unaffected);
  * the `datadog_integration_azure` object.
* The App Service, the AKS cluster, the PostgreSQL server and their data are not in this state and are untouched.
* Monitors, SLOs and dashboards of your organisation are not in this state.
* Application instrumentation applied by the owners (env vars/app settings) must be reverted in the application
  deployments.
* Telemetry already ingested in Datadog follows the organisation's retention; destroy does not delete data.
