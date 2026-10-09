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
