# Changelog

All notable changes to the observability package. Format: Keep a Changelog; versioning: SemVer (see README section 7).

## [1.0.0] - 2026-10-09

### Added
- Manifest-driven onboarding: `schemas/onboarding-manifest.v1.schema.json` (ServiceOnboarding), `archetype.v1`,
  `notification-routing.v1`.
- Archetypes: global defaults; platforms `aks` (+ARO), `aca`, `appservice`, `functions`, `vm` (+VMSS, SF managed),
  `aci`, `logicapp`; resources `database-sql`, `database-postgresql`, `database-mysql`, `database-cosmos`,
  `database-storage`, `messaging` (Service Bus, Event Hubs), `cache` (Managed Redis, Azure Cache for Redis);
  profiles `http-api`, `frontend`, `worker`, `durable-workflow`, `job`, `db-adapter`, `telemetry-pipeline`.
- `tools/onboarding/render.py` (deterministic merge + `--check`, `references`) and `validate.py` (schema + semantic).
- Terraform modules: `onboarding`, `monitors`, `slos` (metric + time-slice SLOs, multi-window burn-rate alerts),
  `synthetics` (API + browser, private locations, paused by default), `dashboards` (per service + application
  overview with journey, databases, queues/durable workflows and telemetry pipeline sections), `service-catalog`
  (entity v3), `rum`, `notification-routing`, `deployment-markers`.
- `tools/verify/telemetry_verify.py` (RUM -> APM -> logs correlation, duplicate detection, required tags,
  infrastructure metrics; bounded polling; JSON evidence), `tools/markers/send_deployment_event.py` (DORA API).
- `tools/release/package.sh` (deterministic tarball, sha256, portability gate).
- Azure DevOps templates (validate, plan, apply saved plan, telemetry verification, deployment markers).
- `examples/existing-environment` consumer root vendoring a versioned release.
