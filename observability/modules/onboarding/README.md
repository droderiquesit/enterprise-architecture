# modules/onboarding

Composition module: rendered service documents (`tools/onboarding/render.py`) -> notification routing, monitors,
SLOs + burn-rate alerts, synthetics, dashboards, Software Catalog entities and quiet-hours downtimes.

Inputs: `services` (list of decoded rendered JSON), `routing` (decoded NotificationRouting), `contract_references`
(map for `${contract:...}` / `presence_ref`), `synthetics`, `dashboards`, `service_catalog`, `slos_enabled`,
`extra_tags`, `strict_references`. Outputs: `summary` (fails on unresolved required references / malformed ids),
`resources` (ids used verbatim + Datadog scope), `monitor_ids`, `slo_ids`, `burn_rate_monitor_ids`,
`synthetic_test_ids`, `synthetics_skipped`, `dashboard_urls`, `catalog_entity_ids`.

Resource scope = `subscription_id:<sub>,resource_group:<rg>,[server_name:<server>,]name:<name>` (lower-cased), the
tag set used by Datadog's recommended Azure monitors. Creates only Datadog objects.
Tests: `terraform test` (mock provider; fixtures rendered from `tests/fixtures/manifests`).
