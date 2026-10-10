# Enterprise Hello — .NET workspace

Owner: applications / .NET builder. Status (ADR-0001 §11): **locally-verified** (unit/integration tests, docker images
built and run, Functions host smoke with Azurite + SQL Server container). Nothing here has been deployed.

| Path | What |
|---|---|
| `EnterpriseHello.sln` | all .NET projects (src + tests) |
| `global.json` | SDK `10.0.401`, `rollForward: latestFeature`; `test.runner = Microsoft.Testing.Platform` (xUnit v3 on MTP — run `dotnet` commands **from this directory**) |
| `Directory.Build.props` | `net10.0`, nullable, analyzers `latest-recommended`, `TreatWarningsAsErrors` for src projects, NuGet audit, provenance (`GIT_COMMIT`, `BUILD_TIME` → assembly metadata) |
| `Directory.Packages.props` | Central Package Management (latest stable on nuget.org, 2026-10-09) + transitive pinning |
| `nuget.config` | nuget.org only, with package source mapping |
| `build.sh` | build → test → publish into `.artifacts/<svc>/` (pipeline entry point) |
| `../shared/dotnet/Hello.Common` | shared library (below) |
| `../services/{bff,orders-api,inventory-api,durable}` | services, each with `src/`, `tests/`, `Dockerfile`, `README.md` |

Each service/shared tree has a one-line `Directory.Build.props` / `Directory.Packages.props` that imports the files
here (MSBuild discovers them by walking up from the project directory).

## Hello.Common

| Feature | API |
|---|---|
| Service identity | `HelloServiceInfo` (OTEL_SERVICE_NAME > DD_SERVICE; DD_ENV; DD_VERSION; GIT_COMMIT; BUILD_TIME; assembly metadata fallback) |
| OpenTelemetry | `AddHelloOpenTelemetry` — resource `service.name/version/namespace=enterprise-hello/instance.id`, `deployment.environment.name` + legacy `deployment.environment`, `git.commit.sha`, plus `OTEL_RESOURCE_ATTRIBUTES` (team/domain/tier); traces: ASP.NET Core (probes filtered), HttpClient, `Hello.App`, `Azure.*` (Azure SDK ActivitySource switch on), optional SqlClient; metrics: `Hello.App` meter, ASP.NET Core, HttpClient, runtime. OTLP exporter only when an endpoint variable is set (honours `OTEL_EXPORTER_OTLP_*`, `OTEL_TRACES_SAMPLER(_ARG)`, `OTEL_BSP_*` — SDK defaults are bounded: queue 2048, batch 512, 5 s delay, 30 s export timeout); metrics temporality **delta** unless `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` is set. **Logs are never exported via OTLP** (ADR-0001 §10). |
| JSON logs | `AddHelloJsonLogging` — console formatter `hello-json`, one object per line: `timestamp, level, message, logger, service, env, version, trace_id, span_id, dd.trace_id, dd.span_id (decimal low 64 bits), dd.service, dd.env, dd.version`, event id/name, structured fields, scope fields, `error.kind/message/stack`. Redaction of `password/secret/token/*key/sig=` pairs, bearer tokens and sensitive field names. `LOG_LEVEL`; optional `LOG_FILE_PATH` sink (same lines, bounded queue, rotation 10 MB × 3, `LOG_FILE_MAX_BYTES`/`LOG_FILE_MAX_FILES`). |
| Probes | `MapHelloOperationalEndpoints(prefix)` → `/healthz`, `/readyz` (all `IReadinessCheck`s, 2 s each, 503 + detail), `/version` |
| Faults | `FaultState` + `FaultInjectionMiddleware` + `/admin/faults` (404 unless `FAULTS_ENABLED=true`; `X-Fault-Token` vs `FAULT_TOKEN` compared constant-time over SHA-256; types `http_500, latency, db_error, dependency_timeout`; `duration_seconds` 1..900; auto-expiry; probes/admin exempt) |
| HTTP clients | `AddHelloHttpClient<T>` — `SocketsHttpHandler` pooling (5 min lifetime), `hello.http.dependency.duration` handler, `AddStandardResilienceHandler` (total/attempt timeouts, retries with exponential backoff + jitter **for safe methods only** unless opted in, circuit breaker), innermost `dependency_timeout` fault handler |
| Problems | RFC 7807 everywhere (`AddProblemDetails`, `HelloExceptionHandler`, status-code pages), `type = urn:enterprise-hello:problem:<code>`, `trace_id` extension |
| Idempotency | `IdempotencyKey` (header validation, request fingerprint) |
| Secrets (Delinea DSV, ADR-0001 §14) | `builder.Configuration.AddDsvSecrets()` (called first by `AddHelloServiceDefaults`; explicitly in hello-durable `Program.cs`) — every configuration value starting with `dsv://<path>#<element>` is resolved at host build time and overlaid under the same key; fail-fast `DsvSecretResolutionException` naming keys only; values never logged. `DsvSecretResolver`: `ManagedIdentityCredential(AZURE_CLIENT_ID)` / `WorkloadIdentityCredential` (when `AZURE_FEDERATED_TOKEN_FILE`) → token for `https://management.azure.com/.default` → DSV `POST /v1/token` azure grant (or `client_credentials` locally) → `GET /v1/secrets/<path>`; DSV token refreshed at 80 % of `expiresIn`, secret cache `DSV_CACHE_TTL_SECONDS` (900), `DSV_TIMEOUT_SECONDS` (5), bounded jittered retries on connection errors/timeouts/429/5xx only (`DSV_MAX_ATTEMPTS` 3), optional `DSV_REFRESH_SECONDS` periodic re-resolution with configuration reload. `DSV_AUTH=none` + any dsv:// value = start-up error; `http://` base URL only for loopback or `DSV_ALLOW_INSECURE_HTTP=true`. Functions: only worker-read settings may be dsv:// (the host reads `AzureWebJobsStorage`/trigger connections itself — use identity-based connections) |
| Identity | `AzureCredentialFactory` — WorkloadIdentityCredential (AKS) → ManagedIdentityCredential(`AZURE_CLIENT_ID`) → DefaultAzureCredential |
| Metrics | `HelloMetrics` (meter `Hello.App`): `hello.orders.created`, `hello.orders.publish_failures`, `hello.orders.status_transitions`, `hello.http.dependency.duration` (s), `hello.inventory.reservations`, `hello.workflow.completed`, `hello.workflow.duration` (ms), `hello.faults.injected`, `hello.idempotency.replays` — bounded attributes only |
| Web defaults | `AddHelloServiceDefaults` / `UseHelloServiceDefaults` / `MapHelloServiceEndpoints` (PORT binding, Kestrel limits, snake_case JSON, `traceparent` response header) |

## Common environment

`PORT` (8080), `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `GIT_COMMIT`, `BUILD_TIME`, `OTEL_SERVICE_NAME`,
`OTEL_RESOURCE_ATTRIBUTES`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL` (`grpc` | `http/protobuf`),
`OTEL_TRACES_SAMPLER(_ARG)`, `LOG_LEVEL`, `LOG_FILE_PATH`, `FAULTS_ENABLED`, `FAULT_TOKEN`, `AZURE_CLIENT_ID`,
`DSV_AUTH`, `DSV_TENANT`, `DSV_TLD`, `DSV_BASE_URL`, `DSV_TIMEOUT_SECONDS`, `DSV_CACHE_TTL_SECONDS`, `DSV_MAX_ATTEMPTS`, `DSV_REFRESH_SECONDS`
(any value may be a `dsv://` reference — secrets such as `FAULT_TOKEN` and connection strings must be).

## Telemetry modes: `TELEMETRY_SDK = otel | datadog` (one tracer per process)

Same variables as Python (`applications/shared/python/hello_common/README.md`). `AddHelloOpenTelemetry` resolves the
mode with `HelloTelemetryMode` and returns `null` (no `OpenTelemetryBuilder`) when it registers no OTel SDK.

| Variable | Effect in Hello.Common |
|---|---|
| `TELEMETRY_SDK` | `otel` (default) — OTel SDK traces/metrics + OTLP as before. `datadog` — **no** TracerProvider/MeterProvider/OTLP exporter registered. Unset + Datadog CLR profiler attached (`CORECLR_ENABLE_PROFILING=1` + `CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8}`, or `COR_*`, or `Datadog.Trace` loaded) ⇒ `datadog`. Explicit `otel` + attached profiler ⇒ WARNING "two tracers". Invalid ⇒ start-up exception |
| `OTEL_SDK_DISABLED=true` | no OTel provider (either mode); in datadog mode a WARNING: the tracer maps it to `DD_TRACE_OTEL_ENABLED=false` |
| `DD_TRACE_OTEL_ENABLED=true` | **required in datadog mode** (the deployment sets it; Hello.Common cannot): `System.Diagnostics.Activity` spans (`Hello.App` producer/consumer/workflow spans, Durable Task worker spans) are recorded by the Datadog tracer — locally verified: `send order-events` (otel.library.name `Hello.App`) appears in the same Datadog trace as `aspnet_core.request` |
| `DD_METRICS_OTEL_ENABLED` | `false` (default): `DogStatsdMetricsBridge` (MeterListener on meter `Hello.App` only) forwards `hello.*` to DogStatsD via `DogStatsD-CSharp-Client` 9.2.1 — counter/up-down → count, histogram → distribution, gauge → gauge; id-like tag keys dropped. `true`: the tracer (≥ 3.30, .NET 6+) exports the Meter over OTLP to the Agent itself (Agent OTLP receiver required; do not add OTel SDK packages) and the bridge is not registered |
| `DD_DOGSTATSD_URL` / `DD_AGENT_HOST` + `DD_DOGSTATSD_PORT` | DogStatsD destination (default `localhost:8125`; `unix:///…` supported); `DD_ENV/DD_SERVICE/DD_VERSION` become `env/service/version` tags |
| `DD_PROFILING_ENABLED` | read by the CLR profiler only (SSI / serverless-init / site extension; Linux also needs `LD_PRELOAD=…/Datadog.Linux.ApiWrapper.x64.so`, set by the injectors). Hello.Common never sets or changes `CORECLR_*`, `COR_*`, `LD_PRELOAD` or `DD_*` (unit-tested); without the profiler attached an INFO line says the setting is ignored |
| `DD_LOGS_INJECTION` | harmless: the tracer's `dd_*` ILogger scope keys are skipped; JSON logs keep the same field names |

Log correlation (`HelloJsonLogWriter`) and the `traceparent` response header / Service Bus `traceparent` /
problem `trace_id` use the **active Datadog span** first (`DatadogCorrelation`: reflection on the auto-instrumentation
`Datadog.Trace` assembly — `Tracer.Instance.ActiveScope.Span` TraceId/SpanId + 128-bit `RawTraceId`; no NuGet
reference), then `Activity.Current`; no span ⇒ fields omitted. (Without this, ASP.NET Core's own Activity — not the
Datadog span — would be reported: observed locally before the fix.)

Recommended deployment defaults for datadog mode (observability instrumentation module): `TELEMETRY_SDK=datadog`,
`DD_TRACE_OTEL_ENABLED=true`, `DD_ENV/DD_SERVICE/DD_VERSION`, `DD_TAGS=team:…,domain:…,tier:…` (instead of
`OTEL_RESOURCE_ATTRIBUTES`), `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED=true` (otherwise .NET HTTP client spans
get service `hello-orders-api-http-client`, observed), `DD_PROFILING_ENABLED=true` where wanted, no `OTEL_EXPORTER_OTLP_*`
/ `OTEL_SDK_DISABLED`. .NET probes are traced by the tracer's ASP.NET Core integration: drop them Agent-side with
`DD_APM_IGNORE_RESOURCES="GET /healthz,GET /readyz,GET /version,GET /api/healthz"` (Python drops them in-process).

## NuGet lock files

`RestorePackagesWithLockFile=true` (Directory.Build.props): every project has a committed `packages.lock.json`.
`build.sh build` restores with `--locked-mode` (drift fails with NU1004; `RestoreLockedMode` is also on whenever
`ContinuousIntegrationBuild=true`), the Dockerfiles copy the lock files into the restore layer and restore with
`--locked-mode`. Hello.Common declares `RuntimeIdentifiers linux-x64;win-x64` so the inventory-api win-x64/linux-x64
publishes stay within the lock files. After changing `Directory.Packages.props`: `LOCKED_RESTORE=false ./build.sh build`
(regenerates the lock files) and commit them.

## Build, test, package

```bash
cd applications/dotnet
dotnet build EnterpriseHello.sln -c Release          # 0 warnings, 0 errors (warnings are errors in src)
dotnet test --solution EnterpriseHello.sln -c Release # 79 tests
VERSION=1.2.3 GIT_COMMIT=$(git rev-parse --short HEAD) ./build.sh all        # build + test + publish
VERSION=1.2.3 CA_BUNDLE=/path/ca.crt ./build.sh images bff orders-api      # docker images (optional CA secret)
```

`build.sh` publish outputs (each with `build-info.json` = service, version, commit, build_time, sha256 per zip):

| Service | Command (as run by build.sh) | Artifact |
|---|---|---|
| durable | `dotnet publish src/Hello.Durable -c Release -o publish` → zip **contents** | `.artifacts/durable/hello-durable-<ver>.zip` — Flex Consumption one-deploy (`host.json`, `functions.metadata`, `.azurefunctions/` at root) |
| inventory-api | `dotnet publish … -c Release -r win-x64 --self-contained true` | `.artifacts/inventory-api/hello-inventory-api-<ver>-win-x64.zip` (App Service Windows / Windows VM service; includes `web.config`, `Hello.InventoryApi.exe`) |
| inventory-api | `dotnet publish … -c Release -r linux-x64 --self-contained false` | `.artifacts/inventory-api/hello-inventory-api-<ver>-linux-x64.zip` (App Service Linux `DOTNETCORE|10.0` / Linux VM) |
| bff, orders-api | `dotnet publish … -c Release -p:UseAppHost=false` | `.artifacts/<svc>/hello-<svc>-<ver>.zip` (portable; production artifact is the container image) |

All publish commands also pass `-p:Version=$VERSION -p:GIT_COMMIT=$GIT_COMMIT -p:BUILD_TIME=$BUILD_TIME -p:ContinuousIntegrationBuild=true`.

Docker images (build context = `applications/`): `services/<svc>/Dockerfile` with BuildKit-specific
`Dockerfile.dockerignore`; SDK `mcr.microsoft.com/dotnet/sdk:10.0.401-noble`; runtime
`mcr.microsoft.com/dotnet/aspnet:10.0.12-noble-chiseled-extra` (distroless, uid 1654, ICU + tzdata for SqlClient/Cosmos);
durable on `mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0`; inventory Windows image
`Dockerfile.windows` (`aspnet:10.0.12-nanoserver-ltsc2025`, not buildable on Linux). Optional build secret
`ca_bundle` for TLS-intercepting proxies (never copied into the image).

## Local verification record (2026-10-09, this sandbox)

| Check | Command / result |
|---|---|
| Release build | `dotnet build EnterpriseHello.sln -c Release` → 0 warnings, 0 errors |
| Tests | `dotnet test --solution EnterpriseHello.sln -c Release` → 79 passed (Common 25, orders 16, inventory 6, bff 10, durable 22) |
| Pipeline script | `VERSION=0.1.0-ci ./build.sh all` → exit 0, 5 zips + build-info.json |
| Images | `docker build` bff / orders-api / inventory-api / durable → OK (245 / 339 / 280 MB uncompressed; durable ≈1.3 GB base) |
| E2E (memory) | bff → orders-api (`STORAGE_MODE=memory MESSAGING_MODE=log PRICE_FALLBACK=true`) + inventory-api: `/healthz` 200, `/version` JSON, `POST /api/orders` 202 with `traceparent` continuing the caller's trace id, replay → `Idempotent-Replayed: true`, GET by id/list, CORS preflight headers, catalog unset → 503 problem; orders logs carry `dd.trace_id=11803532876627986230` for trace `4bf92f3577b34da6a3ce929d0e0e4736` |
| SQL | orders-api against `mcr.microsoft.com/mssql/server:2022-latest`: migration applied, re-applied after restart (no-op), idempotent create, 409 on key reuse, PATCH status |
| Log file sink | `LOG_FILE_PATH` on a bind mount → JSON lines written |
| OTLP | OTLP/HTTP sink received `/v1/traces` + `/v1/metrics` from orders-api and hello-durable (no `/v1/logs` from the ASP.NET services) |
| Functions | `func` 4.15.2 via npm + Azurite + SQL container: batch (12 items) Completed, rows in `fulfillment.batch_runs`; reconciliation Completed; `OrderProcessing` happy path → order `Fulfilled`, inventory reserved, SQL fulfillment row; insufficient stock → `Failed`; unreachable partner with `PAYMENT_TIMEOUT_SECONDS=5` → `payment_timeout`, reservation released, order `Failed`. Durable container image: batch Completed against Azurite. |

Not verified here: Azure SQL/Cosmos/Service Bus with managed identity, Entra JWT validation with real tokens, the
Windows image, Flex Consumption deployment (no Azure credentials in the sandbox).
