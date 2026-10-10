# Deployment profiles

A profile (`<profile>.yaml`, schema [`../schema/profile.schema.json`](../schema/profile.schema.json)) declares:

- `components` — the components the profile enables (`tools/config/resolve.py --env <env>` prints the resolved set);
- `features` — high-level switches, turned into component settings by `tools/config/render.py` (table below);
- `component_settings.<id>` — explicit per-component settings defaults.

Overview, cost estimates and examples per profile: [docs/guides/deployment-profiles.md](../../docs/guides/deployment-profiles.md).

## Settings precedence

`tools/config/render.py --env <env> --component <id>` renders `<root>/terraform.tfvars.json`. A root's `settings`
object is the deep merge of (lowest to highest precedence):

1. root `variables.tf` / `settings.tf` defaults (applied by Terraform for anything not rendered);
2. **profile `features`**, mapped to settings by [`tools/config/features.py`](../../tools/config/features.py);
3. profile `component_settings.<id>`;
4. `environments/<env>/environment.yaml` `components.<id>`.

Maps are merged key by key; lists and scalars are replaced. The rendered settings are part of each component's
fingerprint, so editing a feature re-selects only the components it maps to.

## Feature mapping

| Feature | Value | Component | Settings path |
|---|---|---|---|
| `topology` | `single-spoke` \| `hub-spoke` | foundation-network | `topology` |
| `egress` | `nat-gateway` \| `firewall` | foundation-network | `egress` |
| `firewall` | bool | foundation-network | `firewall_subnet` |
| | | foundation-edge | `firewall.enabled` |
| `bastion` | bool | foundation-edge | `bastion.enabled` (Developer SKU by default: no `AzureBastionSubnet` needed; for Basic/Standard also set `components.foundation-network.bastion_subnet: true`) |
| `app_gateway` | bool | foundation-network | `appgw_subnet` |
| | | foundation-edge | `app_gateway.enabled` |
| `front_door` | bool | foundation-edge | `front_door.enabled` |
| `apim` | bool | foundation-edge | `apim.enabled` |
| `service_bus_sku` | `Standard` \| `Premium` | platform-messaging | `sku` |
| `rum_session_sample_rate` | 0–100 | obs-prereqs | `rum_applications.hello-frontend.session_sample_rate` |
| `session_replay` | bool | obs-prereqs | `rum_applications.hello-frontend.session_replay_sample_rate` (`true` ⇒ 100, `false` ⇒ 0) |
| `trace_sample_rate` | 0–1 | deploy-core-aks, deploy-core-aca, deploy-durable, deploy-functions, deploy-partner-sim, deploy-dbadapters, deploy-appservice, deploy-jobs, deploy-vm-workloads | `trace_sample_ratio` (`OTEL_TRACES_SAMPLER_ARG`) |

Documented-only features (accepted, rendered nowhere):

| Feature | Why |
|---|---|
| `private_endpoints` | private endpoints are the ADR-0001 §8 default of every root; exceptions are per-root settings (`network_mode`, `private_endpoint_enabled`, ...) |
| `deploy_lab_infrastructure` | `observability-only` enables no lab infrastructure through its `components` list |

Any other key in `features` is rejected by `tools/config/lib.py` (`load_profile` and `render_component`), so a new
feature must be added to `FEATURE_MAP` (or `DOCUMENTED_ONLY`) together with this table. Tests:
[`tests/tools/test_profile_features.py`](../../tests/tools/test_profile_features.py) (including a check that every
target settings path exists in the root's `settings` type).

### Prerequisites the mapping cannot supply

- `app_gateway: true` (profiles `full`, `specialized`) enables Application Gateway in foundation-edge, whose validation
  requires `components.foundation-edge.app_gateway.backend_fqdns` in the environment file and the listener
  certificate in Delinea DSV (`<prefix>/<env>/appgw-tls-pfx`, passed by the pipeline); plan fails with that message
  until they are set (or set the feature to `false`).
- `front_door: true` likewise requires `components.foundation-edge.front_door.origins`.
- `egress: firewall` requires `topology: hub-spoke` and `firewall: true` (foundation-network validation).

## Profile-specific component settings

- `minimal`: `platform-containerapps.ingress_mode: external`; `platform-messaging.subscriptions` = only
  `fulfillment` (hello-durable is the only `order-events` consumer in the profile; subscriptions without a
  consumer would retain every order event until TTL).
- `enterprise`, `full`, `specialized`: `platform-containerapps.ingress_mode: internal`; ACR Premium with private
  endpoint and public access disabled.

## Observability settings (package 3.0.0)

Not features: set them per environment in `environments/<env>/environment.yaml` `components.<id>` (or per profile in
`component_settings.<id>`). Types and defaults: the root's `variables.tf`; descriptions: the root README.

| Component | Settings | Meaning |
|---|---|---|
| `obs-telemetry-transport` | `fleet` | overrides of `observability/config/fleet-policy.yaml`, merged as `environments.<env>` (e.g. `{log_pipeline: fluent_bit_direct}`, `{apm: {mode: otel}}`); published in the contract as `env.fleet` |
| `obs-telemetry-transport` | `op_pipeline_id`, `op_hosting`, `op_workload_profile_name`, `op_buffer_storage`, `op_azure_files_storage`, `op_daily_quota_bytes` | Observability Pipelines Worker (central log pipeline): existing pipeline id or create, hosting, buffer, platform-log quota |
| `obs-telemetry-transport` | `apm_gateway_hosting`, `apm_gateway_max_replicas` | Datadog Agent APM gateway for managed runtimes (contract `env.apm_gateway`) |
| `obs-kubernetes` | `ssi_namespaces` | Single Step Instrumentation target namespaces (fleet `apm.mode = datadog`) |
| `obs-prereqs` | `rum_applications.<key>.{mode, application_id, client_token}` | `mode: create` (default) or `existing` with the id + client token of an existing RUM application |
| `obs-azure-integration` | `log_management` | 2.x setting, accepted and **ignored** since package 3.0.0 (log indexes/metrics are not managed by the package); remove it from environment files |
