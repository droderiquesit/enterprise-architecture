# lab/telemetry-transport (component `obs-telemetry-transport`)

**Owner:** observability (transport & collection). **Purpose:** maps the lab contracts to the portable
`modules/telemetry-transport`. It creates an Event Hubs namespace (app-logs and platform-logs hubs), the
Fluent Bit aggregator and the OTel gateway (Container Apps, internal ingress).

* **Consumes:**
  * `foundation_network` (`subnets["private-endpoints"]`, `private_dns_zones["privatelink.servicebus.windows.net"]`)
  * `foundation_identity` (key_vault_id/uri, `identities["obs-collector"]`, `secret_ids["datadog-api-key"]`)
  * `platform_containerapps` (environment_id, default_domain, workload_profiles)
* **Produces:** `obs-telemetry-transport` v1 (`output "contract"`). The schema was extended with optional fields
  only: `otlp.{headers_secret_id, default_protocol, node_agent_*_port, host_agent_grpc_endpoint,
  gateway_distribution, internal_only, logs_policy}`, `fluentbit.{sidecar_forward_config, sidecar_parsers,
  sidecar_lua, sidecar_mode, logs_intake_host, forward_shared_key_secret_id, forward_tls, metrics_port,
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
* `grant_key_vault_secrets_user`

* `eventhub_secret_version` (1): `value_wo_version` of the write-only listen secret; increment after renewing the
  authorization rule keys (docs/runbooks/secret-rotation.md)
* `batch_log_setup_enabled` (true): publish `batch_log_setup` in the contract (below)

## Batch log setup (`batch_log_setup`)
ADR-0001 §13: the contract carries a gzip+base64 Linux installer rendered from
`modules/host-agents/scripts/linux-install.sh.tftpl` with the `linux-host` Fluent Bit config (`batch.tf`): pinned
Fluent Bit 5.1.3, no Datadog Agent, Datadog API key read from Key Vault on the node with the identity named in
`EH_IDENTITY_CLIENT_ID`, tail paths from `EH_LOG_PATHS` (`$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt`).
deploy-jobs runs it as the Batch job preparation task. No secrets are rendered.

## Cost at defaults
About $110/month. Event Hubs Standard 1 TU is about $22; two always-on 0.5 vCPU / 1 GiB Container Apps are about
$80; the private endpoint is about $7.5. Datadog ingestion is extra. See `modules/telemetry-transport/README.md`.

## Teardown / retention
Destroy removes the resource group `<prefix>-rg-obs-<env>-<region>-transport`, which deletes the namespace (1-day
retention, lost) and the apps. The Key Vault secret `eventhub-fluentbit-listen` goes into Key Vault soft delete.

## Private networking
* Receivers are on ACA internal ingress only, and public ingress is rejected by validation.
* Event Hubs denies public traffic, allows trusted services (diagnostic settings), and is reached through a
  private endpoint when foundation publishes the private-endpoints subnet and the servicebus DNS zone.

## Known limitations / exceptions
* SAS (Listen) for the Kafka input on ACA. See the module README.
* AzAPI is used for the Container Apps (azurerm gap).
* The Container Apps sidecar `sub_path` secret mounts are unverified on Azure.
* The apply identity needs Key Vault Secrets Officer to write the listen secret: add its principal id to `components.foundation-identity.secret_officer_principal_ids`.

## Docs
- `observability/modules/README-transport.md`
- `observability/modules/telemetry-transport/README.md`
