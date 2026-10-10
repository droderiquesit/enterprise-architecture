# lab/telemetry-transport (component `obs-telemetry-transport`)

**Owner:** observability (transport & collection). **Purpose:** maps the lab contracts to the portable
`modules/telemetry-transport`. It creates an Event Hubs namespace (app-logs and platform-logs hubs), the
Fluent Bit aggregator and the OTel gateway (Container Apps, internal ingress).

* **Consumes:**
  * `foundation_network` (`subnets["private-endpoints"]`, `private_dns_zones["privatelink.servicebus.windows.net"]`)
  * `foundation_identity` v2 (`identities["obs-collector"]`, `secrets.{tenant, tld, base_url, base_path, refs}`)
  * `artifacts["img-dsv-fetch"].image` (digest-pinned dsv-fetch image, registry artifact)
  * `platform_containerapps` (environment_id, default_domain, workload_profiles)
* **Produces:** `obs-telemetry-transport` **v3** (`output "contract"`, `catalog/contracts/obs-telemetry-transport.v3.schema.json`;
  v3 formalises the 3.0.0 fleet fields: `aggregator.{kind, log_pipeline, pipeline_id, agent_logs_url, eventhub_consumer}`,
  `gateway.apm`, `env.fleet` (`EH_LOG_PIPELINE`, `EH_APM_MODE`, `EH_PROFILING_ENABLED`) and `env.apm_gateway`
  (`DD_TRACE_AGENT_URL`); v2 is kept for 2.x package producers / rollback). As in v2:
  DSV references (`api_key_ref`, `otlp.headers_ref`, `fluentbit.forward_shared_key_ref`) and `secrets` (DSV endpoint +
  `fetch_image`) instead of Key Vault ids. Earlier optional additions: `otlp.{ default_protocol, node_agent_*_port, host_agent_grpc_endpoint,
  gateway_distribution, internal_only, logs_policy}`, `fluentbit.{sidecar_forward_config, sidecar_parsers,
  sidecar_lua, sidecar_mode, logs_intake_host, forward_tls, metrics_port,
  aca_console_allow}`, `event_hub.{kafka_endpoint, consumer_group, location, activity_logs_hub}`, `log_routes`, `aggregator`,
  `gateway`.

## Settings (`components.obs-telemetry-transport`)
* `datadog_site`, `api_key_secret_name`, `forward_shared_key_secret_name` (default `fluentbit-shared-key`; the
  value is set out of band), `collector_identity_key`
* `event_hub_mode`, `event_hub_capacity` (lab ceiling 1–2 TU), `event_hub_private_endpoint`,
  `event_hub_activity_logs_hub` (default `activity-logs`: control-plane logs of `obs-diagnostics`; `""` shares `platform-logs`)
* `aggregator_hosting`, `gateway_hosting`, `gateway_distribution`, `gateway_sampling`,
  `gateway_sampling_percentage`, `gateway_otlp_logs` (drop)
* `*_max_replicas` (≤ 5 in the lab), `workload_profile_name`, `sidecar_mode`
* `aca_console_allow` (default `["<prefix>-caj-*"]`: jobs only)
* package 3.0.0 fleet collection:
  * `fleet`: per-environment overrides of `observability/config/fleet-policy.yaml`, merged as `environments.<env>`
    (e.g. `{log_pipeline: fluent_bit_direct}`, `{apm: {mode: otel}}`, `{profiling: {enabled: false}}`); null = policy as committed
  * `op_pipeline_id` (existing Observability Pipelines pipeline; null = create it), `op_hosting` (`container_app`),
    `op_workload_profile_name` (null = `workload_profile_name`), `op_buffer_storage` (`emptydir` | `azure_files`),
    `op_azure_files_storage`, `op_daily_quota_bytes` (Azure platform logs quota in the pipeline; 0 = none)
  * `apm_gateway_hosting` (`container_app`), `apm_gateway_max_replicas` (≤ 5 in the lab)

* `eventhub_listen_secret_name` (`eventhub-fluentbit-listen`): DSV secret the aggregator reads; after apply the
  pipeline runs `tools/secrets/publish.py --output generated_secrets`, which writes the sensitive output
  `generated_secrets["eventhub-fluentbit-listen"]` (the generated Listen connection string) to DSV. Rotation:
  regenerate the rule key, apply, publish again (docs/runbooks/secret-rotation.md)
* `fetch_artifact` (`img-dsv-fetch`)
* `batch_log_setup_enabled` (true): publish `batch_log_setup` in the contract (below)

## Batch log setup (`batch_log_setup`)
ADR-0001 §13: the contract carries a gzip+base64 Linux installer rendered from the Batch-specific
`scripts/batch-log-setup.sh.tftpl` with the `linux-host` Fluent Bit config (`batch.tf`): pinned Fluent Bit 5.1.3,
no Datadog Agent (Batch is, besides `log_pipeline = fluent_bit_direct`, the only place Fluent Bit remains in 4.0.0),
tail paths from `EH_LOG_PATHS` (`$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt`). deploy-jobs runs it as
the Batch job preparation task. No secrets are rendered.

* Observability Pipelines (default): Fluent Bit forwards to the in-VNet Worker; no API key and no dsv-fetch on the node.
* `fluent_bit_direct`: the node downloads the **static dsv-fetch release** (`artifacts["img-dsv-fetch"].package_url`,
  the img-dsv-fetch zip-package) with the pool identity named in `EH_IDENTITY_CLIENT_ID` (IMDS token for Azure
  Storage; the pool identity already reads the packages store for the svc-jobs package), checks the pinned
  `package_sha256` and `SHA256SUMS`, installs `dsv-fetch-linux-<arch>` root-only (0500) and the Fluent Bit unit's
  `ExecStartPre` reads the API key from Delinea DSV into a tmpfs file. The output precondition fails the plan when the
  package URL/sha256 are missing. No Python is involved (package 4.0.0 retired the 1.x `dsv_fetch.py`).

## Cost at defaults
About $110/month. Event Hubs Standard 1 TU is about $22; two always-on 0.5 vCPU / 1 GiB Container Apps are about
$80; the private endpoint is about $7.5. Datadog ingestion is extra. See `modules/telemetry-transport/README.md`.

## Teardown / retention
Destroy removes the resource group `<prefix>-rg-obs-<env>-<region>-transport`, which deletes the namespace (1-day
retention, lost) and the apps. The DSV secret `eventhub-fluentbit-listen` is not touched (delete it in DSV).

## Private networking
* Receivers are on ACA internal ingress only, and public ingress is rejected by validation.
* Event Hubs denies public traffic, allows trusted services (diagnostic settings), and is reached through a
  private endpoint when foundation publishes the private-endpoints subnet and the servicebus DNS zone.

## Known limitations / exceptions
* SAS (Listen) for the Kafka input on ACA. See the module README.
* AzAPI is used for the Container Apps (azurerm gap).
* The Container Apps sidecar `sub_path` secret mounts are unverified on Azure.
* Secrets in state: the Event Hubs authorization rules' computed keys/connection strings (azurerm), and the sensitive
  output `generated_secrets` (same value). Nothing else; no Key Vault.
* dsv-fetch init containers need the **Consumption** workload profile (managed identity for init containers).

## Docs
- `observability/modules/README-transport.md`
- `observability/modules/telemetry-transport/README.md`

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/lab.tftest.hcl`. From the repository root: `python3 tools/validate/all_terraform.py --only obs-telemetry-transport` (fmt, validate, test).
