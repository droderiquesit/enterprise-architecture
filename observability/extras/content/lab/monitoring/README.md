# obs-monitoring (lab root)

- **Owner**: observability layer (monitoring-as-code content). Component id `obs-monitoring`; runs after every selected
  application deployment.
- **Purpose**: onboard every deployed Enterprise Hello service into Datadog from the committed rendered manifests
  (`observability/onboarding/rendered/<env>/*.json`) with the package module `modules/onboarding`: monitors, SLOs +
  burn-rate alerts, synthetics, per-service dashboards + the Enterprise Hello overview (journey, databases, queues /
  durable workflows, telemetry pipeline), Software Catalog (system `enterprise-hello`), quiet-hours downtimes.
- **Consumed contracts**: `obs-prereqs` (typed variable `obs_prereqs`); all other upstream contracts (deploy-*,
  platform-*, obs-telemetry-transport) as a flat `contract_references` map produced by the pipeline:
  `python3 observability/tools/onboarding/render.py references --contracts-dir <materialized contracts> --out references.auto.tfvars.json`.
  Contract paths used by the lab manifests (must exist in the producing contracts):
  `deploy-frontend.url`, `deploy-core-aca.apps.<svc>.{id,url}`, `deploy-appservice.apps.hello-inventory-api.{id,url}`,
  `deploy-durable.function_app.id`, `deploy-functions.function_apps.premium.id`, `deploy-partner-sim.{url,container_group.id}`,
  `deploy-jobs.jobs.seed.id`, `deploy-core-aks.apps.hello-worker.id`, `deploy-dbadapters.adapters.<family>.{id,url}`,
  `platform-db-sql.databases.{orders,fulfillment,adapter}.id`, `platform-db-postgresql.server.id`,
  `platform-messaging.namespace_id`, `platform-db-*.{account,server,cache,...}.id` (optional), `obs-telemetry-transport.otlp.grpc_endpoint`,
  `obs-telemetry-transport.event_hub.namespace_id`. A service whose `presence_ref` is absent is skipped.
- **Produced contract**: none (outputs `summary`, `dashboard_urls`, `synthetics_skipped` for the deployment record).
- **Settings** (`components.obs-monitoring`): `synthetics_enabled` (true), `synthetics_paused` (true: created paused to
  avoid cost), `private_location_id` (null -> private endpoint tests skipped), `service_dashboards`, `overview_dashboard`,
  `journey`, `service_catalog`, `slos_enabled`, `create_webhooks`, `rendered_dir`, `routing_file`.
- **Notification routing**: `observability/onboarding/routing/<env>.yaml` (dev: e-mail only, nobody paged).
- **Cost at defaults**: no Azure cost. Datadog: monitors/SLOs/dashboards are not billed separately; synthetic API tests
  are billed per 10k runs (paused by default; live at 5-minute ticks from one location ~8.6k runs/month per endpoint);
  browser tests per 1k runs (15-minute tick when live ~2.9k runs/month).
- **Teardown / retention**: `terraform destroy` removes only Datadog configuration objects. Telemetry data is unaffected.
- **Networking**: Datadog SaaS API only. Private endpoints need a Datadog private location (not created here).
- **Lab content outside the package**: `observability/onboarding/<env>` (manifests), `rendered/<env>`, `routing/<env>.yaml`
  are lab inputs and are excluded from the package tarball.
- **Regenerate**: `python3 observability/tools/onboarding/render.py render --manifests observability/onboarding/dev --env dev --out observability/onboarding/rendered/dev`
  (CI: same with `--check`).
- **Docs**: https://registry.terraform.io/providers/DataDog/datadog/latest/docs , https://docs.datadoghq.com/monitors/ ,
  https://docs.datadoghq.com/service_management/service_level_objectives/burn_rate/
- **Checks**: `terraform init -backend=false && terraform validate && terraform test` (mock provider).
