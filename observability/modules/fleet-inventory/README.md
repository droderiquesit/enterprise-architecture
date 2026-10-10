# modules/fleet-inventory

One fleet inventory input -> one collection plan per resource (pure, no providers).

`resources` maps a stable key to an object with these fields:

* `id`: literal ARM id;
* `type`: ARM type;
* `architecture`, `runtime`, `os_type`: for application resources;
* `tags`: the rendered tags of the owning service;
* `app_log_route`, `tier`: optional overrides.

The plan gives each signal exactly one authoritative collector. Columns:

* `metrics`: the Azure integration.
* `platform_logs`: diagnostic settings, when the category policy knows the type.
* `app_logs`: `datadog_agent`, `fluent_bit_sidecar`, `fluent_bit_host`, `eventhub` and so on.
* `log_destination`: `observability_pipelines` or the `datadog_intake`.
* `agent`.
* `apm`: an SSI flavour, `agent_gateway`, `otel`, `rum` or `none`.
* `dbm`.

| Output | Feeds |
|---|---|
| `diagnostic_targets` | `modules/diagnostic-settings` `resources` |
| `scope_tags` | `modules/observability-pipeline` `azure.scope_tags` / Fluent Bit aggregator `FLB_AZURE_SCOPE_TAGS`: platform logs of a resource carry its owner's tags |
| `dbm_candidates` | `modules/dbm` (host and auth still per database) |
| `matrix` | reports / the per-resource matrix in `docs/guides/datadog-fleet-collection.md` |
