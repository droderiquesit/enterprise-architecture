# hello-orders-api (.NET 10)

Owner: applications / .NET builder. Component: `svc-orders-api` (artifact: container image `hello-orders-api`).

Order intake for Enterprise Hello. Prices orders through hello-catalog-api, stores them in Azure SQL
(database `orders`, schema `orders`), publishes `OrderCreated` to the Service Bus topic `order-events`, and accepts
status updates from hello-durable.

## Data boundary

| Owns | Does not own |
|---|---|
| Azure SQL DB `orders`, schema `orders` (tables `orders.orders`, `orders.idempotency`, `orders.schema_version`) | catalog data (hello-catalog-api), fulfillment data (hello-durable, schema `fulfillment`) |

The schema migration (`src/Hello.OrdersApi/Data/Migrations/0001_orders_schema.sql`) runs at startup, is idempotent,
and is serialised across replicas with `sp_getapplock`. `/readyz` reports `not_ready` until it has completed.
The platform root creates the server and database and grants the workload identity `db_ddladmin` + data access
(the migration needs `CREATE SCHEMA`/`CREATE TABLE`).

## Endpoints

| Method | Path | Notes |
|---|---|---|
| POST | `/orders` | body `{sku, quantity (1..1000), customer_ref}`, header `Idempotency-Key` (required, ≤128 printable ASCII). 202 + order, `Location: /orders/{id}`. Same key + same body → same order, header `Idempotent-Replayed: true`. Same key + different body → 409 problem `idempotency-key-reused`. |
| GET | `/orders?limit=20&since=<ISO-8601>` | `{items:[order], count}`; limit 1..100, newest first |
| GET | `/orders/{id}` | 404 problem when unknown |
| PATCH | `/orders/{id}/status` | internal (hello-durable). `{status: Reserved\|Charged\|Fulfilled\|Failed, reason?, workflow_instance_id?}`. Forward-only, idempotent for the same status, 409 for invalid transitions or terminal orders |
| POST | `/orders/{id}/republish` | re-publishes `OrderCreated` for `Pending`/`PublishFailed` orders (MessageId = order id → broker duplicate detection) |
| GET | `/healthz`, `/readyz`, `/version` | readiness checks SQL (2 s) + migration state |
| POST/GET/DELETE | `/admin/faults` | lab fault injection (see below) |

Order JSON (snake_case): `id, sku, quantity, unit_price, amount, status, customer_ref, created_at, updated_at,
status_reason, workflow_instance_id`. Errors are RFC 7807 `application/problem+json` with `type`
`urn:enterprise-hello:problem:<code>` and a `trace_id` extension.

Service Bus message (topic `order-events`): body `{"event":"OrderCreated","order_id","sku","quantity","amount","created_at"}`,
`MessageId = CorrelationId = order_id`, `Subject = OrderCreated`, ApplicationProperties `traceparent`, `tracestate`
(W3C context of the producer span) and `event`. The Azure SDK additionally stamps `Diagnostic-Id`. A publish failure
leaves the order in `PublishFailed` (counter `hello.orders.publish_failures`) — retry with `/republish`. No outbox.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | 8080 | listen port |
| `STORAGE_MODE` | `sql` if `SQL_CONNECTION_STRING` set, else `memory` | `sql` \| `memory` (tests/local only) |
| `SQL_CONNECTION_STRING` | — | Azure: `Server=tcp:<fqdn>,1433;Database=orders;Authentication=Active Directory Managed Identity;User Id=<client-id>;Encrypt=True` (driver auth via `Microsoft.Data.SqlClient.Extensions.Azure`). AKS workload identity: omit `Authentication=` and set `SQL_USE_AZURE_CREDENTIAL=true`. Local docker: SQL auth. |
| `SQL_USE_AZURE_CREDENTIAL` | false | token callback from `AzureCredentialFactory` (workload identity → managed identity → DefaultAzureCredential) |
| `MESSAGING_MODE` | `servicebus` | `servicebus` \| `log` (no broker; event logged) |
| `SERVICEBUS_FQDN` | — | `<ns>.servicebus.windows.net` (managed identity) |
| `SERVICEBUS_CONNECTION_STRING` | — | emulator/local only |
| `SERVICEBUS_TOPIC` | `order-events` | |
| `CATALOG_API_URL` | — | hello-catalog-api base URL (`GET /products/{sku}`, reads `price`) |
| `PRICE_FALLBACK` | false | **local tests only**: when `CATALOG_API_URL` is unset, price = 5.00 + 2.50 × (SKU number mod 20) |
| `AZURE_CLIENT_ID` | — | user-assigned managed identity client id |
| common | | `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `GIT_COMMIT`, `BUILD_TIME`, `OTEL_*`, `LOG_LEVEL`, `LOG_FILE_PATH`, `FAULTS_ENABLED`, `FAULT_TOKEN` — see [applications/dotnet/README.md](../../dotnet/README.md) |

Outbound HTTP (catalog): 5 s total, 2 s per attempt, 2 retries with jitter for GET, circuit breaker.
Service Bus: 2 retries, 5 s try timeout, 15 s overall publish budget.

## Telemetry

- Spans: ASP.NET Core server, HttpClient (catalog), SqlClient (`microsoft.sql_server`), Azure SDK (`ServiceBusSender.Send`),
  `send order-events` (producer, `Hello.App` source, `messaging.*` attributes).
- Metrics: `hello.orders.created{order.status}`, `hello.orders.publish_failures`, `hello.orders.status_transitions{order.status}`,
  `hello.idempotency.replays`, `hello.http.dependency.duration{peer.service,http.request.method,http.response.status_code,error.type}`,
  `hello.faults.injected{fault.type}`, ASP.NET Core / HttpClient / runtime / SqlClient instruments. No ids in attributes.
- Logs: JSON per line (ADR-0001 §9) with `order_id`, `sku`, `quantity`, `amount`, `from_status`/`to_status`, `workflow_instance_id`.

## Fault injection (lab)

`FAULTS_ENABLED=true` + `FAULT_TOKEN` (from Key Vault). `POST /admin/faults` with `X-Fault-Token`:
`{"type":"http_500|latency|db_error|dependency_timeout","rate":0..1,"latency_ms":int,"duration_seconds":1..900}`.
`db_error` makes repository calls fail with 503; `dependency_timeout` makes catalog calls hang until the resilience
timeout (→ 504). Faults expire automatically.

## Run locally

```bash
cd applications/dotnet
STORAGE_MODE=memory MESSAGING_MODE=log PRICE_FALLBACK=true dotnet run --project ../services/orders-api/src/Hello.OrdersApi
curl -s -X POST localhost:8080/orders -H 'content-type: application/json' -H 'Idempotency-Key: k1' \
  -d '{"sku":"SKU-0001","quantity":1,"customer_ref":"c1"}'
```

Container: `docker build -f applications/services/orders-api/Dockerfile -t hello-orders-api:dev applications`
(context = `applications/`; image `mcr.microsoft.com/dotnet/aspnet:10.0.12-noble-chiseled-extra`, uid 1654).
`LOG_FILE_PATH` must point to a mounted writable volume (the root filesystem is read-only friendly).

## Test

```bash
cd applications/dotnet && dotnet test --project ../services/orders-api/tests/Hello.OrdersApi.Tests
```

WebApplicationFactory tests: health/ready/version, POST idempotency (replay + key reuse 409), validation problems,
status transitions, publish failure → `PublishFailed` → republish, catalog-not-configured 503, fault auth (404/403/400),
`http_500` expiry with a fake clock, `db_error` 503 and `DELETE` clear.
Locally verified against SQL Server 2022 in docker (migration on first start and again after restart, idempotent create,
409 on key reuse, PATCH status) — see the .NET README.

## Limitations

- No transactional outbox; `PublishFailed` + republish is the recovery path.
- `PATCH /orders/{id}/status` is protected by network placement only (internal ingress), not by an app-level token.
