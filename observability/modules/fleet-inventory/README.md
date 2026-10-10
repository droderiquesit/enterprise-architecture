# modules/fleet-inventory

One fleet inventory input -> one collection plan per resource (pure, no providers).

`resources` maps a stable key to an object with these fields:

* `id`: literal ARM id;
* `type`: ARM type;
* `architecture`, `runtime`, `os_type`: for application resources (`architecture` defaults from the type, e.g.
  `Microsoft.Web/sites` -> `appservice`; set `functions` for Function Apps; no `runtime` = a tracer runtime);
* `tags`: the rendered tags of the owning service;
* `app_log_route`, `tier`: optional overrides.

The plan gives each signal exactly one authoritative collector. Log collector and APM method come from
`modules/fleet-policy` resolved per resource (same per-architecture defaults and overrides as
`modules/instrumentation`). Columns:

* `metrics`: the Azure integration.
* `platform_logs`: diagnostic settings, when the category policy knows the type.
* `app_logs`: `datadog_agent` (AKS, VM / VMSS), `datadog_agent_sidecar` (ACI), `serverless_init` (Container Apps),
  `eventhub` (diagnostic settings), `eventhub_console_allow_list` (Container Apps environments); fallback
  `fluent_bit_daemonset` / `fluent_bit_sidecar`; `fluent_bit_host` (Batch).
* `log_destination`: `observability_pipelines` or the `datadog_intake`.
* `agent`: `datadog_agent_helm`, `datadog_agent_vm_application`, `datadog_agent_sidecar`, `serverless_init` or `none`.
* `apm`: the Datadog method (`ssi_kubernetes`, `ssi_host`, `serverless_init`, `agent_sidecar`, `agent_gateway`),
  `otel`, `rum` or `none`.
* `dbm`.

| Output | Feeds |
|---|---|
| `diagnostic_targets` | `modules/diagnostic-settings` `resources` |
| `scope_tags` | `modules/observability-pipeline` `azure.scope_tags` / Fluent Bit aggregator `FLB_AZURE_SCOPE_TAGS`: platform logs of a resource carry its owner's tags |
| `dbm_candidates` | `modules/dbm` (host and auth still per database) |
| `matrix` | reports / the per-resource matrix in `docs/guides/datadog-fleet-collection.md` |

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/inventory.tftest.hcl`.
