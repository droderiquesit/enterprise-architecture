# OTel gateway configs

| File | Purpose |
|---|---|
| `gateway.yaml` | base. OTLP 4317/4318; memory_limiter, resourcedetection(env), resource/unified_tags, probabilistic_sampler, batch; datadog/connector (APM stats on 100% of spans), datadog exporter; logs accepted and dropped (`nop`); self-telemetry `without_type_suffix` + env label |
| `gateway-auth.yaml` | bearertokenauth on both protocols (upstream only) |
| `gateway-tail-sampling.yaml` | tail_sampling (errors, >1s, probabilistic baseline). Requires a single replica. |
| `gateway-scrape-fluentbit.yaml` | Prometheus scrape of the aggregator's `/api/v2/metrics/prometheus` (env label) |
| `gateway-logs-forward.yaml` | opt-in: forward OTLP logs to Datadog (duplicates if a Fluent Bit route exists) |

Overlays are merged with repeated `--config`: maps merge, lists replace. Environment variables used:
* files `/dsv-secrets/dd-api-key` (and `/dsv-secrets/otlp-bearer-token` with the auth overlay), written by the
  `dsv-fetch` init container (`init --format files`) from Delinea DSV; env `DD_SITE`, `DD_ENV`
* `TRACE_SAMPLING_PERCENTAGE`, `GATEWAY_MEMORY_LIMIT_MIB`, `GATEWAY_MEMORY_SPIKE_MIB`
* `SELF_SCRAPE_INTERVAL`, `FLUENTBIT_METRICS_TARGET`
* DDOT only: `DD_HOSTNAME`

Validated with `otelcol-contrib validate` (all overlays) and run end to end for both images in
`observability/tests/transport/test_otel_gateway.py`.
