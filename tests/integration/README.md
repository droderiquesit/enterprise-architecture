# Local end-to-end integration run (Enterprise Hello + telemetry plumbing)

Owner: integration/test engineering. Status this produces: **locally-verified (docker, mock Datadog intake)** — never
"verified" in the ADR-0001 §11 sense: nothing is deployed and no data reaches Datadog.

One run starts the Enterprise Hello vertical slice with docker compose, drives a real Chromium browser journey and
asserts, against the telemetry actually captured, that

> a browser journey produces a RUM event, correlated API traces, downstream service and database spans, application
> logs transported through Fluent Bit, durable workflow/messaging telemetry; required telemetry is present, correctly
> tagged and not duplicated; every secret comes from (mock) Delinea DSV and no secret value reaches logs or the intake.

Evidence is written to `docs/evidence/local/<UTC timestamp>/` and summarised in `docs/evidence/local/LATEST.md`.

## Prerequisites

| Need | Notes |
|---|---|
| Docker Engine + Compose v2 | ~25 containers, ~6 GB RAM, ~8 GB disk for images (SQL Server 2.3 GB, Functions base 1.3 GB) |
| python3.13, `pip install playwright==1.56.0` | Python Playwright 1.56 drives Chromium revision 1194; no browser download needed when one is installed |
| Chromium | `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers` (default used by the runner) or `PW_CHROMIUM_EXECUTABLE=/path/to/chrome` |
| Images `hello-<svc>:0.1.0-e2e`, `dsv-fetch:0.1.0-e2e` | built from the current source by `build_images.sh` (automatically when missing; dsv-fetch from `observability/images/dsv-fetch`, base `gcr.io/distroless/python3-debian13` pinned by digest) |

No Playwright docker image is used. Infrastructure images: `mcr.microsoft.com/mssql/server:2022-latest`,
`mcr.microsoft.com/azure-messaging/servicebus-emulator:latest`, `mcr.microsoft.com/azure-storage/azurite:latest`,
`postgres:17-alpine`, `redis:7-alpine`, `python:3.13-slim` (mock intake, volume init), `fluent/fluent-bit:5.1.3`,
`otel/opentelemetry-collector-contrib:0.162.0`. If Docker Hub rate-limits, pull `mirror.gcr.io/library/<image>` and
`docker tag` it to the name above.

## Run

```bash
python3 tests/integration/run_e2e.py              # build missing images, up, journey, checks, evidence, down -v
python3 tests/integration/run_e2e.py --rebuild    # rebuild all nine app images from the current source first
python3 tests/integration/run_e2e.py --keep       # leave the stack running (ports below) for debugging
python3 tests/integration/run_e2e.py --reuse --keep   # run journey + checks again against a running stack
E2E=1 pytest -v tests/integration/test_e2e.py     # same run, one pytest test per check (E2E_KEEP=1, E2E_REBUILD=1)
tests/integration/build_images.sh [svc ...]       # just (re)build hello-<svc>:0.1.0-e2e (E2E_VERSION overrides)
docker compose -f tests/integration/docker-compose.yml -p eh-e2e down -v   # manual teardown
```

Exit code 0 only when every check passes. A clean run takes ~2 minutes after images exist (of which ~35 s is the
fault-injection window). `test_e2e.py` is skipped unless `E2E=1`, so the repository's normal `pytest` stays docker-free.

Behind a TLS-intercepting proxy `build_images.sh` passes `CA_BUNDLE` (default `/root/.ccr/ca-bundle.crt` when present)
as the build secrets the Dockerfiles already accept (`ca_bundle` .NET, `pipca` Python/npm) and forwards `HTTPS_PROXY`
with `--network host`. Images are tagged with the git revision label; the evidence records whether the application
source (`applications/services`, `applications/shared`) differs from the image revision.

Host ports (127.0.0.1 only): frontend 18080, BFF 18081, catalog 18082, orders 18083, inventory 18084, partner-sim 18085,
dbadapter-postgresql 18086, worker health 18087, durable 18088, mock intake 18090 (`GET /_received`), gateway health 18133,
mock DSV 18200 (`GET /v1/__calls`: method, path, identity - never values).

## What is real, emulated, mocked

| Component | Local form | Real / emulated / mocked |
|---|---|---|
| hello-frontend (React + Datadog Browser RUM SDK 7.x) | repo nginx image + mounted `config/frontend/config.json` | real (served by its production nginx config + CSP) |
| hello-bff, orders-api, inventory-api, durable (.NET 10) | images built from repo Dockerfiles | real code |
| hello-catalog-api, partner-sim, worker, dbadapter-postgresql (Python 3.13) | images built from repo Dockerfiles | real code |
| Azure SQL (orders + fulfillment) | SQL Server 2022 Developer; DBs `orders`, `fulfillment` created by `config/mssql/init.sql`; schemas/tables by the apps' own migrations | real engine, SQL auth instead of Entra |
| PostgreSQL Flexible Server (catalog, adapter) | `postgres:17-alpine`; DB `adapter` by `config/postgres/init.sql` | real engine, password auth, no TLS |
| Azure Managed Redis | `redis:7-alpine` on 6379, no auth/TLS | real engine |
| Azure Service Bus (topic `order-events` + subs fulfillment/notifications/audit/archive, queue `batch-items`) | official emulator + `config/servicebus/config.json` (shares the SQL Server) | **emulated** |
| Azure Storage (Durable task hub, worker table `notifications`) | Azurite (in-memory) | **emulated** |
| Cosmos DB NoSQL (inventory) | hello-inventory-api `STORAGE_MODE=memory` | **not covered** (Cosmos emulator too heavy for this sandbox) |
| Fluent Bit sidecar per app | `fluent/fluent-bit:5.1.3` running `observability/config/fluent-bit/sidecar.yaml` + `parsers.yaml` + `lua/` **unmodified**, tailing the app's `LOG_FILE_PATH` on a shared volume | real; only env differs: `FLB_DD_HOST=intake`, `FLB_DD_PORT=8080`, `FLB_DD_TLS=off` (test-only override) |
| OTel gateway | collector-contrib 0.162.0 with `observability/config/otel/gateway.yaml` **unmodified** + `config/otel/e2e-overlay.yaml` (second `--config`) | real; overlay points the `datadog` exporter's `traces.endpoint`/`metrics.endpoint` at the mock intake (plain HTTP) and adds a `file` exporter for span/metric assertions |
| Datadog logs / APM / metrics intake | `observability/tests/transport/mock_intake` (reused, unmodified) | **mocked** |
| Delinea DSV | `tools/secrets/mock_dsv.py` in `python:3.13-slim` with `config/dsv/mock-dsv.json` (one DSV identity per workload, read on its own `eh/e2e/<workload>/*` paths only) | **mocked**. Apps authenticate with `DSV_AUTH=client_credentials` (the managed-identity `azure` grant needs IMDS/IDENTITY_ENDPOINT, absent locally; it is unit-tested against the same mock with fake Entra tokens) |
| Secrets in app env | `FAULT_TOKEN`, `SQL_CONNECTION_STRING`, `SERVICEBUS_CONNECTION_STRING`, `TABLES_CONNECTION_STRING`, `PG_PASSWORD`, `PG_USER` (dbadapter) are `dsv://eh/e2e/...` references, resolved in-process at start-up by `hello_common.secrets.resolve_env()` / `Hello.Common` `AddDsvSecrets()` | real code. Exceptions (literal, read by the Functions **host**, which cannot resolve dsv://): hello-durable `AzureWebJobsStorage`, `ServiceBusConnection` - identity-based in Azure |
| DD_API_KEY for Fluent Bit + OTel gateway | `dsv-fetch` init services (`dsv-fetch-flb`: `--format env-yaml` -> `/dsv-secrets/fluentbit-env.yaml`, included by the unmodified `sidecar.yaml`; `dsv-fetch-otel` as uid 10001: `--format files` -> `/dsv-secrets/dd-api-key` for `gateway.yaml` `${file:...}`) on tmpfs volumes; `depends_on: service_completed_successfully`; no `DD_API_KEY` env anywhere | real init-container pattern. `dsv-secrets-holder` keeps the tmpfs volumes mounted (docker drops a tmpfs volume's content when its last container exits; an ACA/k8s emptyDir lives with the pod) |
| Datadog RUM intake | the frontend has no RUM `proxy` option, so a Playwright route on `https://browser-intake-datadoghq.com/**` records each RUM batch, forwards it unchanged (same path + query) to the mock intake and answers the browser `202` + CORS | **mocked** (interception documented in evidence: `forwarded_to_mock_intake`) |

App telemetry env mirrors `observability/modules/instrumentation` for a gateway target (`OTEL_EXPORTER_OTLP_ENDPOINT`
grpc, `OTEL_RESOURCE_ATTRIBUTES` with service.namespace/team/domain/tier/application/owner/region,
`OTEL_LOGS_EXPORTER=none`, `LOG_FILE_PATH`), and each sidecar gets the module's `FLB_DD_SERVICE/SOURCE/TAGS`.

hello-durable has no `LOG_FILE_PATH` sink (the Functions host owns stdout; in Azure its logs travel FunctionAppLogs ->
diagnostic settings -> Event Hubs -> Fluent Bit aggregator). Locally the host console stream is `tee`'d into the shared
volume, so its lines arrive as plain-text multiline records (no JSON, no trace_id). The Event Hubs/Kafka aggregator
path itself is tested by `observability/tests/transport`.

## Checks (all asserted with bounded polling)

1. **RUM**: view, resource (incl. the BFF calls) and action events captured and forwarded to the mock intake; the
   `POST /api/orders` resource event's `_dd.trace_id` matches the request's `traceparent`.
2. **Trace correlation**: the browser `traceparent` trace id appears in hello-bff (server span parented by the browser
   span), hello-orders-api, hello-catalog-api spans and hello-orders-api's SQL Server client span; PostgreSQL/Redis spans
   in that trace and in the product-list trace are reported.
3. **Durable**: `orchestration:OrderProcessing` + ReserveInventory/ChargePayment/RecordFulfillment/UpdateOrderStatus
   activity spans for instance `order-<id>`, in (or linked to) the order's trace; order reaches `Fulfilled` in the UI.
4. **Worker**: `servicebus.process` consumer span in its own trace with a span link to hello-orders-api's producer span.
5. **Logs**: every app's logs reached the intake via its Fluent Bit sidecar with `ddsource`, `service`, `ddtags`
   (`env`, `service`, `version`, `team`, `telemetry.pipeline:fluent-bit`); journey log lines carry the browser trace id
   and `dd.trace_id` == decimal low 64 bits, `dd.span_id` == decimal span id; gzip + API key header on every request.
6. **No duplicates**: one unique marker log per service occurs exactly once; no identical structured events; repeated
   plain-text host lines are compared with the source file; no duplicated span ids.
7. **Tags**: required resource attributes on every app's spans and metrics, RUM `ddtags` env/service/version, no
   order id in metric attributes, `hello.workflow.completed` present.
8. **Redaction**: a fake secret logged by an app (partner-sim `order_id`) and a raw line appended to a shared log file
   (bypassing the in-process redactor: Bearer token, SAS `sig`, `client_secret`, connection-string password) never
   reach the intake unredacted.
9. **Faults**: orders-api `POST /admin/faults` wrong/missing token 403, catalog-api (`FAULTS_ENABLED=false`) 404,
   http_500 rate 1.0 for 30 s -> BFF returns 5xx -> recovers after expiry and the fault list is empty.
10. **Idempotency**: same `Idempotency-Key` + body -> same order (`Idempotent-Replayed: true`), one order stored;
    same key + different body -> 409 (recorded).
11. **Exporter transport**: the gateway's datadog exporter delivered traces/stats/series/sketches to the mock intake with
    an API key; the gateway accepted OTLP logs (Functions host) and dropped them (`nop`), so logs reach the intake only
    via Fluent Bit.
12. **Secrets from DSV**: the mock DSV call log shows each workload identity authenticating and reading exactly its
    own paths (orders-api 3, durable 2, catalog-api 1, dbadapter 1, worker 2, observability 1 - shared by both dsv-fetch
    inits), no unauthenticated reads; both dsv-fetch init services exited 0; the secret files are 0400, owned by the
    consumer uid (65532 Fluent Bit env file, 10001 collector key file) on tmpfs; and no secret value (each mock DSV
    value, the password/key parts of connection strings, the DSV client secrets) occurs in any intake payload, any
    container log of our components or the gateway's file exports. Check 9 (FAULT_TOKEN), readiness (SQL/PG/Service
    Bus/Tables) and check 5/11 (API keys) prove the resolved values are the ones in use.

## Known gaps

- Real Delinea DSV and the managed-identity `azure` grant (mock DSV with `client_credentials`; see check 12).
- Cosmos DB (inventory runs in memory), Cosmos emulator not used.
- Entra ID everywhere: BFF `AUTH_MODE=none`, SQL/PostgreSQL password auth, connection strings for Service Bus/Storage
  instead of managed identity.
- Event Hubs / Kafka aggregator path (App Service, Functions, Logic Apps logs) and `sidecar-forward.yaml` are not part
  of this run (covered by `observability/tests/transport`).
- Azure Monitor diagnostic settings / platform metrics / Datadog Azure integration, DBM.
- Real Datadog ingestion, indexing, pipelines, monitors and UI: the intake is a mock that only records payloads
  (Datadog-native trace/metric payloads are counted by path, not decoded; span content is asserted from the gateway's
  file exporter).
- The RUM SDK is fed by route interception rather than a configured `proxy`; hello-frontend has no proxy option.
- Only the `postgresql` dbadapter family is included.
