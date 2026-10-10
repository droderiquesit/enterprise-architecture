# hello_common — shared runtime for Enterprise Hello Python services

Installable package (`pip install ./applications/shared/python/hello_common`; services reference it by path via
`[tool.uv.sources]`, Dockerfiles copy it from the `applications/` build context). Owner: application platform team.

| Module | What it provides |
|---|---|
| `config` | `env_str/int/float/bool/choice`, `ServiceInfo` (DD_SERVICE/DD_VERSION/DD_ENV/GIT_COMMIT/BUILD_TIME), `listen_port()` |
| `logging` | `JsonFormatter` + `configure_logging()` — ADR §9 log shape, `trace_id`/`span_id` (hex) and `dd.trace_id`/`dd.span_id` (decimal low 64 bits) from the current OTel span, `error.kind/message/stack`, credential redaction, optional `LOG_FILE_PATH` rotating file (10 MB × 3) |
| `telemetry` | `setup_telemetry()` — OTLP gRPC or HTTP/protobuf (`OTEL_EXPORTER_OTLP_PROTOCOL`), resource (`service.name`, `service.version`, `service.namespace=enterprise-hello`, `deployment.environment.name` + legacy `deployment.environment`, `OTEL_RESOURCE_ATTRIBUTES`), sampler from `OTEL_TRACES_SAMPLER(_ARG)`, bounded `BatchSpanProcessor` (queue 2048, batch 512), metrics with an attribute allow-list View (no ids in metric attributes), instrumentation of httpx, psycopg, redis, pymongo, PyMySQL, logging and azure-core (azure-core-tracing-opentelemetry) |
| `app` | `create_app()` — FastAPI with `/healthz`, `/readyz` (checks run concurrently, 2 s timeout each, 503 problem+json), `/version`, access log line per request, `traceparent` response header, FastAPI instrumentation; `run()` (uvicorn, graceful shutdown) |
| `faults` | default-disabled, token-authenticated (constant-time compare), auto-expiring (≤ 900 s) fault injection: `http_500`, `latency` (middleware), `db_error` (`check_fault()` hook in data layers), `dependency_timeout` (httpx transport hook) |
| `http` | `create_client()/create_async_client()` — timeouts, pooled connections, bounded retries with full jitter for idempotent requests only (GET/HEAD/OPTIONS/PUT/DELETE, POST/PATCH with `Idempotency-Key`), `Retry-After` honoured |
| `idempotency` | `Idempotency-Key` validation and a bounded TTL replay cache |
| `problems` | RFC 7807 `application/problem+json` handlers and `Problem` exception |
| `azure_auth` | `get_credential()` (DefaultAzureCredential / ManagedIdentityCredential / WorkloadIdentityCredential with `AZURE_CLIENT_ID`), `TokenCache` (refreshes 5 min before expiry; used for PostgreSQL/MySQL token-as-password) |
| `secrets` | Delinea DSV (ADR-0001 §14): `resolve_env()` replaces every env var whose value starts with `dsv://<path>#<element>` in-process at start-up (called by every entrypoint and by `create_app`); `DsvClient` — managed identity (`ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)`, `WorkloadIdentityCredential` when `AZURE_FEDERATED_TOKEN_FILE` is set) → `POST /v1/token` azure grant (or `client_credentials` locally), DSV token refreshed at 80 % of `expiresIn`, secret cache (`DSV_CACHE_TTL_SECONDS`, 900), timeouts (`DSV_TIMEOUT_SECONDS`, 5), bounded jittered retries on connection errors/429/5xx only (`DSV_MAX_ATTEMPTS`, 3); fail-fast `SecretResolutionError` naming variables only; values never logged. `DSV_AUTH=none` + any `dsv://` value = start-up error. `http://` base URLs only for loopback or `DSV_ALLOW_INSECURE_HTTP=true` |
| `propagation` | W3C helpers for async boundaries: `links_from_properties()` (span **link** to the producer, never parent), Service Bus bytes-property normalisation, `Diagnostic-Id` fallback |
| `messaging` | `ServiceBusSource` (azure-servicebus async PEEK_LOCK receiver + `AutoLockRenewer`, MI or emulator connection string) and `MemorySource` |
| `testing` | throwaway docker containers for `integration` tests, Service Bus emulator (+ SQL Server) bootstrap |

Tests: `pytest` (unit tests; `tests/test_secrets.py` runs against `tools/secrets/mock_dsv.py`). See `applications/python/README.md` for the build pipeline.

## Telemetry modes: `TELEMETRY_SDK = otel | datadog` (one tracer per process)

`hello_common.apm` selects the tracer at import time (`hello_common/__init__.py` runs before any service imports
FastAPI/httpx/psycopg/redis, which is what `ddtrace.auto` requires). The .NET equivalent is `Hello.Common`
(`HelloTelemetryMode`, see `applications/dotnet/README.md`); both read the same variables.

| Variable | Values / default | Effect |
|---|---|---|
| `TELEMETRY_SDK` | `otel` (default when unset) \| `datadog`; anything else fails start-up | `otel`: OTel SDK tracer + meter providers, OTLP exporters, OTel instrumentations (unchanged behaviour). `datadog`: **no** OTel SDK provider, exporter or instrumentation is created. Unset **and** a Datadog tracer already injected ⇒ `datadog` (safety net); explicit `otel` next to an injected tracer is kept but logged as a WARNING (two tracers) |
| `OTEL_SDK_DISABLED` | `true` | otel mode: no OTel provider at all. **Do not set in datadog mode**: Datadog SDKs map it to `DD_TRACE_OTEL_ENABLED=false` (manual spans dropped; a WARNING is logged) |
| `DD_TRACE_ENABLED` | default true | `false` in datadog mode: ddtrace is not imported (profiler alone if `DD_PROFILING_ENABLED=true`) |
| `DD_TRACE_OTEL_ENABLED` | **set `true`** (hello_common defaults it to `true` when it enables ddtrace itself) | OTel **API** calls (worker `servicebus.process` spans with links, jobs/traffic spans) become ddtrace spans (operation name = span kind, resource = span name); `trace.get_current_span()` returns the active ddtrace span, so `traceparent` propagation helpers keep working |
| `DD_PROFILING_ENABLED` | `true` to enable | datadog mode: Continuous Profiler started by `ddtrace.auto` (ddtrace 4.15.6 ships cp313 profiler extensions; locally verified on Python 3.13.16); injected tracer ⇒ the injector owns it (never started twice). otel mode: ignored with an INFO line (Datadog documents no profiler + OTel SDK pairing) |
| `DD_METRICS_OTEL_ENABLED` | default false | datadog mode, `false`: `hello.*` metrics → **DogStatsD** (`datadog` client 0.55.0). `true`: they stay on the OTel Metrics API and ddtrace's MeterProvider exports OTLP to the Agent (needs the Agent OTLP receiver, ddtrace ≥ 3.18) |
| `DD_DOGSTATSD_URL` / `DD_AGENT_HOST` + `DD_DOGSTATSD_PORT` | default `localhost:8125` | DogStatsD destination (`udp://host:8125` or `unix:///var/run/datadog/dsd.socket`) |
| `DD_ENV`, `DD_SERVICE`, `DD_VERSION` | required | unified service tags on spans, logs, DogStatsD metrics (client adds `env:`/`service:`/`version:`) |
| `DD_LOGS_INJECTION` | optional | not needed: the JSON formatter writes the ids itself; ddtrace's record attributes are ignored (same field names) |

Datadog mode details:

* **Tracer source.** Injected (SSI on AKS/VMs `_DD_PY_SSI_INJECT=1`, `ddtrace-run` in a serverless-init entrypoint):
  detected via `ddtrace.bootstrap.sitecustomize` in `sys.modules` and left alone. Otherwise `import ddtrace.auto`
  (`ddtrace==4.15.6` is installed in every service image via `requirements-datadog.in`). Azure Functions: if
  `datadog-serverless-compat` is installed its `start()` runs first (Datadog's documented order) — it is **not** a
  dependency today (see `services/functions/README.md`).
* **Logs.** `trace_id` (32 hex; ddtrace 128-bit ids), `span_id` (16 hex), `dd.trace_id` (decimal low 64 bits),
  `dd.span_id` come from `ddtrace.tracer.current_span()`; omitted when no span is active. Same field names in both modes.
* **Metrics.** `telemetry.meter()` returns a facade: identical call sites, attributes filtered by
  `ALLOWED_METRIC_ATTRIBUTES` in both modes; DogStatsD types: counter/up-down → `count`, histogram → `distribution`,
  gauge → `gauge`; same metric names (`hello.catalog.cache.requests`, `hello.worker.messages`, ...).
* **Probes.** `/healthz`, `/readyz`, `/version` traces are dropped in-process by a ddtrace `TraceFilter`.
* **Not used in datadog mode:** `OTEL_EXPORTER_OTLP_*`, `OTEL_RESOURCE_ATTRIBUTES` (Datadog SDKs map it to `DD_TAGS`;
  set `DD_TAGS=team:…,domain:…,tier:…` instead — do not set both, the Agent would merge duplicates),
  `OTEL_TRACES_SAMPLER` (mapped to `DD_TRACE_SAMPLE_RATE`), azure-core OTel span plugin (ddtrace's `azure_servicebus`
  / `azure_cosmos` integrations cover the SDK calls).

Tests: `tests/test_apm.py` (both modes, each datadog case in a fresh interpreter: no OTel providers/OTLP exporter,
ddtrace-injected detection, log correlation from real ddtrace spans, fake DogStatsD UDP listener, profiler start /
ignore). Real-Agent proof: `tests/integration/run_dd_agent_e2e.py` (evidence `docs/evidence/local/LATEST-datadog-agent.md`).
