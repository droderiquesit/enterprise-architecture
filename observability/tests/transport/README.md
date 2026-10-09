# Transport & collection tests

`./run.sh`: terraform fmt, validate and test for 9 modules and 6 lab roots, contract schema checks, then
`pytest`. Requires docker. Set `TERRAFORM_BIN` to use a wrapper. Set `EH_NETWORK_TESTS=1` to include the host
installer test.

| Test | What it proves (synthetic data, local docker only) |
|---|---|
| `dryrun.sh` / `test_dry_run_all_configs` | `fluent-bit --dry-run` passes for 8 configs |
| `test_fluentbit.py::test_sidecar_direct_to_datadog` | `sidecar.yaml` tails the spec-shaped log file and sends to a mock Datadog intake (`mock_intake/`, gzip-decoding `POST /api/v2/logs`). JSON is parsed; the timestamp becomes the event time; .NET and Python stack traces are merged into one event each; secrets are redacted (key=value, JSON field, Bearer JWT, storage AccountKey); ddsource, service and tags are set; trace_id, span_id and dd.trace_id are kept; no duplicates; the API key header and gzip are present; the self-metrics endpoint keeps `_total`; every record carries `telemetry.pipeline:fluent-bit`; sidecars emit no canary |
| `::test_aggregator_forward_and_eventhub_kafka` | sidecar-forward goes to the aggregator `forward` input (shared key). The aggregator `kafka` input reads Azure diagnostic batches (`{"records":[...]}`) from Apache Kafka 4.1 with SASL PLAIN `$ConnectionString`, the Event Hubs convention. Records are split, app JSON fields are lifted, and `azure.<provider>` source plus resource tags are set. ACA console logs: an allow-listed job is kept; a sidecar app's stdout and the fluent-bit container are dropped. The canary arrives with env and the pipeline tag. |
| `::test_linux_host_config_with_canary` | `linux-host.yaml` tails a glob, emits the canary, and pushes self-metrics over OTLP (names keep `_total`, `env` attribute) to an Agent stand-in |
| `test_otel_gateway.py` (7) | upstream and DDOT run gateway.yaml: OTLP gRPC + HTTP, legacy `deployment.environment` mapped to `deployment.environment.name`, `service.version` default, command line dropped. The real datadog exporter posts traces and APM stats to the mock. Also: bearer auth rejects a wrong token; OTLP logs accepted and dropped by default; forwarded only with the overlay; `otelcol_exporter_send_failed_spans` (no suffix) and `fluentbit_output_errors_total` (with suffix) both carry `env`; all overlays validate |
| `test_dbm_local.py` | DBM SQL scripts (twice) on PostgreSQL 17 and MySQL 8.4; Agent 7.84.2 runs the rendered DBM configs with `ENC[file@...]`; `can_connect` OK, DBM payloads emitted |
| `test_host_installer.py` (network) | rendered Linux installer in ubuntu:24.04: pinned package, dry-run, 0600 env file, Agent drop-in, idempotent, agent-only host |
| `contract_check.py` | `output "contract"` of the mock-provider plans validates against the JSON schemas |

Not covered locally:
* the k8s DaemonSet config at runtime (dry-run only, because the kubernetes filter needs an API server)
* Windows scripts and the `winevtlog` input
* anything against real Azure or Datadog
