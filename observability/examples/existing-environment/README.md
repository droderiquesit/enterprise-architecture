# Example: onboard an EXISTING environment with a versioned package release

Standalone consumer root. It needs nothing from the source repository except the released tarball.

| Existing resource (ids supplied in manifests) | Monitoring created (Datadog only) |
|---|---|
| App Service `app-orders-web-prod` (`manifests/prod/orders-web.yaml`) | APM/5xx/latency/no-traffic, App Service 5xx + response time, synthetic API test, SLO + burn-rate alerts |
| AKS workload `orders-api` on `aks-prod-weu` | APM monitors, kube-state replicas/restarts, latency + availability SLOs |
| PostgreSQL flexible server `psql-orders-prod` | is_db_alive, CPU (threshold 85 via params), failed connections, storage |
| Telemetry pipeline | canary logs, Fluent Bit and OTel collector health |
| Datadog Azure integration (`modules/azure-integration`, existing Entra app, secretless) | platform metrics for all `azure.*` monitors |
| Diagnostic settings (`modules/diagnostic-settings`) on the three resources -> existing Event Hubs | App Service app logs (eventhub route) + platform logs (AKS audit, PostgreSQL logs) |

No sample applications, no networks, platforms or databases are created. Fault injection is disabled and validated.

## Steps

1. Pin the release in `package.lock.json` (`version`, `url`, `sha256` from the release `.sha256` file).
2. `./vendor.sh` - downloads, verifies sha256, extracts to `./.vendor/observability-<version>/` (git-ignored) and checks
   that every module `source` uses that version.
   Alternative without vendoring: `source = "git::https://dev.azure.com/<org>/<project>/_git/<repo>//observability/modules/<module>?ref=observability-v1.0.0"`.
3. Edit `manifests/prod/*.yaml` (resource ids are used **verbatim**), `routing/prod.yaml`, then
   `python3 .vendor/observability-1.0.0/tools/onboarding/validate.py --manifests manifests/prod --env prod --routing routing/prod.yaml --strict`
   and `python3 .vendor/observability-1.0.0/tools/onboarding/render.py render --manifests manifests/prod --env prod --out rendered/prod`.
   Commit `rendered/prod`.
4. `terraform init` (backend: your partial config) -> `terraform plan -out tfplan` -> `terraform apply tfplan`
   with `DD_API_KEY`/`DD_APP_KEY` in the environment. Pipelines: `pipelines/azure-pipelines.consumer-example.yml` in the package.
5. Hand `terraform output instrumentation` to the application owners (App Service app settings, Kubernetes patch,
   env vars, Key Vault secret references). This root never changes application settings.

Tests: `terraform test` (after `./vendor.sh`) runs plan-only checks with a mocked Datadog provider.

## Upgrade

`package.lock.json` -> new version/sha256, `./vendor.sh --update-sources` (rewrites `./.vendor/observability-<old>/`
module sources), re-render, `terraform plan`. A MINOR/PATCH upgrade updates Datadog objects in place; the plan must
not destroy anything outside Datadog (there is nothing else in this state). See the package `UPGRADING.md`.

## Removal safety

* `terraform destroy` of this root removes only the Datadog monitors, SLOs, burn-rate alerts, synthetic tests,
  dashboards, catalog entities and downtimes it created. The App Service, AKS cluster, PostgreSQL server and their data
  are not in this state and are untouched.
* `terraform destroy` also deletes the diagnostic settings this root created (log export stops; the resources and
  their data are unaffected) and the `datadog_integration_azure` object (Datadog stops polling Azure Monitor; the Entra
  app registration and its role assignments are not managed here and stay). Agent Helm releases / VM extensions and
  DBM, when added from the package collection modules, are uninstalled by destroy as well; agents installed outside
  Terraform are removed with Datadog's uninstall procedure (https://docs.datadoghq.com/agent/guide/how-do-i-uninstall-the-agent/).
* Application instrumentation applied by the owners (env vars/app settings) must be reverted in the application
  deployments; without a collector the SDKs simply fail to export.
* Telemetry already ingested in Datadog follows the organisation's retention; destroy does not delete data.
