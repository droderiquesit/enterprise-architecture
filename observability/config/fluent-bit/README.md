# Fluent Bit configs (fluent/fluent-bit:5.1.3, YAML format)

| File | Role | Inputs |
|---|---|---|
| `sidecar.yaml` | ACA/ACI sidecar, direct to Datadog | tail `${LOG_FILE_PATH}*` (multiline `eh_stack`) |
| `sidecar-forward.yaml` | sidecar sending to the aggregator | same tail input; `forward` output with shared key and optional TLS |
| `aggregator.yaml` | observability-subnet aggregator | `forward` (24224) + `kafka` (Event Hubs, SASL_SSL) + canary |
| `aggregator-forward.yaml` | aggregator without an Event Hub | `forward` + canary |
| `k8s-daemonset.yaml` | AKS DaemonSet | tail `/var/log/containers/*.log` (`cri`), multiline, kubernetes filter, throttle, canary, self-metrics over OTLP |
| `linux-host.yaml` / `windows-host.yaml` | VM/VMSS service | tail `${FLB_LOG_PATHS}`, canary, self-metrics over OTLP; `inputs-extra.yaml` include (`linux-host-systemd.yaml` journald / `windows-host-winevtlog.yaml`) |
| `parsers.yaml` | shared | `eh_json` (app JSON, `timestamp` becomes the event time), `eh_stack` multiline (.NET `at ...` frames, Python tracebacks) |
| `lua/enterprise_hello.lua` | shared filters | see the list below |

The filters in `lua/enterprise_hello.lua`:
* `eh_redact`: key=value, JSON fields, `Bearer`, `sig=`, `AccountKey=`
* `eh_normalize`: `log` becomes `message`; trace-id aliases are lifted; `dd.*` is flattened
* `eh_k8s`: service/env/version/ddsource/ddtags from labels
* `eh_static_tags`
* `eh_azure_split`: splits `{"records":[...]}` batches; ACA console allow-list
* `eh_finalize`: adds `telemetry.pipeline:fluent-bit`

## Environment contract (no defaults inside the configs)
The YAML `env:` section overrides process environment variables, so the configs read **process env only**.
Deployers must set every variable they use. The modules do this through `modules/fluent-bit` `env` output.

| Group | Variables |
|---|---|
| Datadog output | `FLB_DD_HOST` (`http-intake.logs.<site>`), `FLB_DD_PORT`=443, `FLB_DD_TLS`=`on` (only the local tests use `off` against the mock), `DD_API_KEY` (secret) |
| Tags and fallbacks | `FLB_DD_TAGS`, `FLB_DD_SOURCE`, `FLB_DD_SERVICE` |
| Input and state | `FLB_STATE_DIR`, `LOG_FILE_PATH`, `FLB_LOG_PATHS`, `FLB_EXCLUDE_PATHS`, `FLB_THROTTLE_RATE` |
| Canary and self-metrics | `FLB_CANARY_INTERVAL_SEC`, `FLB_METRICS_INTERVAL_SEC`, `FLB_OTLP_HOST`, `FLB_ENV` |
| Forward | `FLB_FORWARD_*` (host, port, TLS, `FLB_FORWARD_SHARED_KEY` secret) |
| Event Hubs | `EVENTHUB_BROKERS`, `EVENTHUB_TOPICS`, `EVENTHUB_CONSUMER_GROUP`, `KAFKA_SECURITY_PROTOCOL`=SASL_SSL, `EVENTHUB_CONNECTION_STRING` (secret) |
| ACA console filter | `FLB_ACA_CONSOLE_ALLOW` |

Resilience settings:
* `storage.type: filesystem` on inputs, bounded by `storage.total_limit_size` on outputs
* `mem_buf_limit`, `retry_limit`, `storage.backlog.mem_limit`
* gzip, `net.keepalive`
* health check (`/api/v1/health`, `hc_*`)
* `/api/v2/metrics/prometheus` on 2020

Validation:
* `observability/tests/transport/dryrun.sh` runs `fluent-bit --dry-run` (the flag exists in 5.1.3 and validates
  plugin properties and Lua loading) on every config, plus the journald add-on.
* `winevtlog` exists only in Windows builds, so it is not dry-run.
* The functional tests are in `observability/tests/transport/`.

Entra (OAUTHBEARER) for the kafka input: on VM or AKS hosts you can replace the SAS settings with the following.
This needs the VM IMDS endpoint, so it does not work on ACA. Not locally verified.
```yaml
      rdkafka.security.protocol: SASL_SSL
      rdkafka.sasl.mechanism: OAUTHBEARER
      rdkafka.sasl.oauthbearer.method: oidc
      rdkafka.sasl.oauthbearer.metadata.authentication.type: azure_imds
      rdkafka.sasl.oauthbearer.config: query=api-version=2018-02-01&resource=https://eventhubs.azure.net&client_id=<uami-client-id>
```
References:
- https://docs.fluentbit.io/manual/pipeline/outputs/datadog
- https://docs.datadoghq.com/logs/guide/fluentbit/
- https://docs.fluentbit.io/manual/pipeline/inputs/kafka
- https://docs.fluentbit.io/manual/administration/configuring-fluent-bit/yaml
