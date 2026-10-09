# modules/otel-collector

A pure function module that renders the OTel **gateway** configuration from `observability/config/otel/` as
collector config-provider environment variables:

* `--config=env:OTELCOL_CONFIG_BASE`, followed by the overlays in deterministic order: auth, logs-forward,
  scrape-flb, tail.
* `env` and `secret_env_names` (`DD_API_KEY`, `OTLP_BEARER_TOKEN`).

The config lives in env vars, so you can run the gateway anywhere (ACA, a VM, Kubernetes) without mounting
files.

## Distribution choice (per Datadog guidance, 2026-10)
| distribution | Image | Status here |
|---|---|---|
| `upstream` (default) | `otel/opentelemetry-collector-contrib:0.162.0` + `datadog` exporter + `datadog/connector` | GA path for a self-hosted gateway outside Kubernetes. Locally verified. |
| `ddot` | `datadog/ddot-collector:7.84.2` (`otel-agent run`, standalone) | Datadog documents the DDOT **gateway** as Preview and only for Kubernetes (Helm/Operator). The standalone image runs the same config (locally verified) but needs `DD_HOSTNAME` and does **not** include `bearertokenauth`, `forward` or `file`. With auth enabled it is rejected. |

The Datadog compatibility matrix shows DBM, CNM, live containers and processes only with DDOT or the Agent.
The gateway only handles OTLP traces and metrics from managed runtimes, so the upstream collector loses
nothing there.

## Pipeline (gateway.yaml)
* Receivers: OTLP gRPC on 4317 and HTTP on 4318, internal only.
* `memory_limiter` (80/20% of container memory), then `resourcedetection` (env only, so gateway replicas never
  become hosts), then `resource/unified_tags`. This processor maps legacy `deployment.environment` to
  `deployment.environment.name`, fills `DD_ENV` and `service.version=unknown` when they are missing, and drops
  `process.command_line/args`.
* `traces/stats` (100% of spans) feeds `datadog/connector`, which produces APM stats metrics.
* `traces` goes through `probabilistic_sampler` (or the `tail_sampling` overlay, single replica only) and
  `batch`, then the `datadog` exporter (retry, sending_queue).
* `metrics`: OTLP + connector + self-telemetry (`otelcol_*` with `without_type_suffix: true`, plus an `env`
  label) + optional Fluent Bit scrape.
* `logs`: accepted, then dropped with `nop` by default (README-transport.md §2.4).

References:
- https://docs.datadoghq.com/opentelemetry/compatibility/
- https://docs.datadoghq.com/opentelemetry/setup/ddot_collector/ and https://docs.datadoghq.com/opentelemetry/setup/ddot_collector/install/kubernetes_gateway
- https://docs.datadoghq.com/opentelemetry/setup/collector_exporter/
- https://docs.datadoghq.com/opentelemetry/setup/otlp_ingest/serverless/ (direct OTLP intake: HTTP only, `dd-api-key` header on every client, so it is not used by default; it would put the API key in every app)
- https://opentelemetry.io/docs/collector/configuration/
