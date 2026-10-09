# modules/telemetry-transport

The shared telemetry transport for an **existing** environment. It produces the `obs-telemetry-transport` v1
contract (`catalog/contracts/obs-telemetry-transport.v1.schema.json`).

| Part | Resources (existing-or-new) |
|---|---|
| Event Hubs | `event_hub.mode = create`: Standard namespace (Kafka endpoint, TLS 1.2, default-deny network rules + trusted services, optional private endpoint), hubs `app-logs` and `platform-logs` (2 partitions, 1 day), consumer group `fluent-bit`, SAS rules `diagnostic-settings-send` (Manage+Send+Listen, required by diagnostic settings) and `fluent-bit-listen` (Listen). The listen connection string is written **write-only** to Key Vault. `existing`: bring the namespace id, send rule id and listen secret id. `none`: no Event Hub route. |
| Fluent Bit aggregator | `aggregator.hosting = container_app`: Container App on the provided ACA environment and workload profile. **Internal** TCP ingress on 24224 (forward, shared key, optional TLS from Key Vault) plus an internal port on 2020 (health and self-metrics). `kafka` input against `<ns>.servicebus.windows.net:9093` (SASL_SSL). Datadog output (gzip, TLS). Filesystem buffer bounded by `storage.total_limit_size`, retries, `mem_buf_limit`, health check, canary. `none`: the caller provides `external_endpoint`. |
| OTel gateway | `gateway.hosting = container_app`: upstream contrib (default) or DDOT. **Internal** HTTP ingress (OTLP/HTTP on 4318 behind the environment's HTTPS endpoint) plus an internal TCP port on 4317 (gRPC). Optional bearer-token auth, probabilistic or tail sampling, OTLP logs drop. `none`: `external_endpoints`. |

Secrets: the Datadog API key, the forward shared key, the Event Hubs listen connection string and the TLS
cert/key are Container Apps secrets that point at Key Vault (`keyVaultUrl` + user-assigned identity). The
contract carries only versionless secret ids.

## AzAPI gap (recorded)
`Microsoft.App/containerApps@2025-07-01` is used instead of `azurerm_container_app` (azurerm 5.9), which is
missing two features:
1. `ingress.additionalPortMappings`. The gateway needs 4318 + 4317 and the aggregator needs 24224 + 2020.
2. Secret-volume item paths (`volumes[].secrets[].path`). Fluent Bit needs real `*.yaml` file names to detect the
   YAML format.

## Exception: SAS on Event Hubs
Fluent Bit 5.1.3's `kafka` input (librdkafka 2.15) supports SASL OAUTHBEARER/OIDC, including
`sasl.oauthbearer.metadata.authentication.type=azure_imds`. That mode needs the **VM IMDS** endpoint.
Container Apps managed identities use `IDENTITY_ENDPOINT`, not IMDS, and Entra client-credentials would need a
secret anyway. The aggregator therefore uses a **Listen-only SAS** connection string from Key Vault
(`rdkafka.sasl.username=$ConnectionString`), and the namespace keeps `local_authentication_enabled = true`.
Hosting the aggregator on a VM or AKS node would allow `azure_imds` (Entra) instead.
Locally verified: SASL PLAIN with `$ConnectionString` against Apache Kafka 4.1 (`test_fluentbit.py`).

## Inputs (abridged)
`name_prefix`, `names`, `resource_group {name,id}`, `location`, `tags`, `datadog {site, api_key_secret_id
(versionless), env, extra_tags}`, `collector_identity {id, principal_id, client_id}`, `key_vault {id,
grant_secrets_user}`, `event_hub {..., listen_secret_version (write-only `value_wo_version`; increment to rotate)}`, `container_apps {environment_id, workload_profile_name,
external_ingress=false}`, `aggregator {...}`, `gateway {distribution, sampling, sampling_percentage, otlp_logs,
auth, replicas}`, `sidecar_mode`, `aca_console_allow`, `images`.

Validations include:
* public ingress rejected
* tail sampling requires `max_replicas = 1`
* DDOT + auth rejected
* a versioned or literal API key rejected
* the aggregator requires a shared key
* `existing` Event Hub mode requires all ids

## Outputs
`contract`, `event_hub_namespace_id`, `diagnostics_authorization_rule_id`, `aggregator_id`, `gateway_id`,
`gateway_args`.

## Private networking
ACA internal ingress is reachable only from the environment's VNet and from peered networks.
The callers have to resolve two kinds of DNS names:
* App Service, Functions and VM callers resolve `<app>.internal.<defaultDomain>` through the environment's
  private DNS zone (owned by platform-containerapps).
* The aggregator resolves `privatelink.servicebus.windows.net` (foundation-network).

Diagnostic settings reach Event Hubs as a trusted service.

## Costs at defaults (approx. USD/month, swedencentral list prices, 730 h, no free grants)
* Event Hubs Standard, 1 TU: about $22, plus ingress events at about $0.03 per million.
* Two Container Apps, each with 0.5 vCPU / 1 GiB and min 1 replica, always active: about $40 each.
* Private endpoint: about $7.5.
* **Total about $110**, plus Datadog ingestion.

## Teardown / retention
Destroy removes the namespace, which discards its retained events (1 day), and both apps. The Fluent Bit buffer
is ephemeral and is lost on scale-in. Retries bound the in-flight loss. The Key Vault listen secret is deleted
and goes into Key Vault soft delete.

## References
- https://docs.datadoghq.com/logs/guide/fluentbit/ and https://docs.fluentbit.io/manual/pipeline/outputs/datadog
- https://docs.fluentbit.io/manual/pipeline/inputs/kafka and https://learn.microsoft.com/azure/event-hubs/azure-event-hubs-apache-kafka-overview
- https://learn.microsoft.com/azure/event-hubs/authenticate-shared-access-signature ; librdkafka CONFIGURATION.md (`sasl.oauthbearer.metadata.authentication.type`)
- https://learn.microsoft.com/azure/container-apps/ingress-overview#additional-tcp-ports ; https://learn.microsoft.com/azure/templates/microsoft.app/2025-07-01/containerapps
- https://learn.microsoft.com/azure/container-apps/manage-secrets (Key Vault references)
- https://docs.datadoghq.com/opentelemetry/setup/collector_exporter/
