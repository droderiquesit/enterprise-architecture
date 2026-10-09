# hello-durable (.NET 10 isolated, Durable Functions)

Owner: applications / .NET builder. Component: `svc-durable` (artifacts: zip package for Flex Consumption one-deploy,
container image). .NET 10 isolated worker is supported on Flex Consumption
([supported stacks](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#supported-language-stack-versions)).

## Data boundaries

| Store | Purpose | Connection |
|---|---|---|
| Azure Storage (queues/tables/blobs) | Durable runtime state (task hub `%DURABLE_TASK_HUB%`) — Azure Storage provider | `AzureWebJobsStorage` (identity: `AzureWebJobsStorage__accountName`, `__credential=managedidentity`, `__clientId`) |
| Azure SQL schema `fulfillment` | business data: `fulfillment.fulfillments`, `fulfillment.batch_runs`, `fulfillment.reconciliation_runs` | `SQL_CONNECTION_STRING` (separate from the runtime store) |

The `fulfillment` schema is created by an idempotent, applock-serialised migration on the first SQL use per process
(`src/Hello.Durable/Data/Migrations/0001_fulfillment_schema.sql`). All writes are `MERGE` keyed by natural ids, so
activity retries are idempotent. Identity needs Storage Blob/Queue/Table Data Contributor on the runtime account and
`db_ddladmin` + data access on the SQL database.

## Functions

| Function | Trigger | Behaviour |
|---|---|---|
| `OrderEventsStarter` | Service Bus topic `order-events`, subscription `fulfillment`, connection `ServiceBusConnection` | starts `OrderProcessing` with instance id `order-{order_id}`; skips when the instance exists (at-least-once safe); producer `traceparent` becomes a span **link** on a `process order-events` consumer span (parent = invocation span) |
| `OrderProcessing` | orchestration | `ReserveInventory` → `UpdateOrderStatus(Reserved)` → `ChargePayment` (RetryPolicy 3 attempts, 1 s ×2 backoff) raced against a durable timer (`PAYMENT_TIMEOUT_SECONDS`, default 10) → `UpdateOrderStatus(Charged)` → `RecordFulfillment` (SQL MERGE) → `UpdateOrderStatus(Fulfilled)`. Failure (declined, timeout, activity failure) → compensation `ReleaseInventory` → `UpdateOrderStatus(Failed, reason)` → `RecordFulfillment(Failed)`. Insufficient stock fails without compensation. Custom status `{step, outcome, reason}` |
| `BatchProcessing` | orchestration | fan-out `ProcessItem` × N (≤50, failures isolated per item) → fan-in `BatchSummary` → `RecordBatchRun`; optional `EnqueueBatchItems` to queue `batch-items` |
| `Reconciliation` | orchestration | `GetOrdersSince` (orders-api) + `GetFulfillmentRecordsSince` (SQL) → pure diff (matched, missing_fulfillment, status_mismatch, orphan_fulfillment, stuck) → `RecordReconciliationRun` |
| `StartBatch` | HTTP `POST /api/workflows/batch` `{items:1..50, enqueue?}` | 202 `{instance_id, status_uri}` |
| `StartReconciliation` | HTTP `POST /api/workflows/reconciliation` | 202; instance `reconcile-manual-<yyyyMMddHHmm>` |
| `ReconciliationTimer` | timer `%RECONCILE_SCHEDULE%` | instance `reconcile-timer-<yyyyMMddHHmm>` (window `RECONCILE_WINDOW_HOURS`, default 24) |
| `GetWorkflowStatus` | HTTP `GET /api/workflows/{instanceId}` | `{instance_id, name, runtime_status, created_at, last_updated_at, custom_status, output, failure}`; 404 problem |
| `StartOrderWorkflow` | HTTP `POST /api/workflows/order` (body = OrderCreated message) | lab/smoke entry point when Service Bus is unavailable; same instance-id rule. *Addition to the spec.* |
| `PurgeHistory` | timer `0 15 3 * * *` | purges Completed/Failed/Terminated instances older than `DURABLE_HISTORY_RETENTION_DAYS` (7) |
| `Healthz`, `Version` | HTTP `GET /api/healthz`, `/api/version` | |
| activities | | `ReserveInventory`, `ReleaseInventory`, `ChargePayment`, `RecordFulfillment`, `UpdateOrderStatus`, `ProcessItem`, `RecordBatchRun`, `EnqueueBatchItems`, `GetOrdersSince`, `GetFulfillmentRecordsSince`, `RecordReconciliationRun` |

HTTP functions use `AuthorizationLevel.Anonymous`: the app is expected to be reachable only privately (inbound access is
owned by the deployment root). Orchestrators are deterministic (context time, no I/O, `CreateReplaySafeLogger`).

## Configuration (app settings)

| Setting | Required | Notes |
|---|---|---|
| `FUNCTIONS_WORKER_RUNTIME=dotnet-isolated` | yes | Flex sets the runtime via `functionAppConfig`; keep for other plans |
| `AzureWebJobsStorage__accountName` (+ `__credential=managedidentity`, `__clientId`) | yes | runtime + Durable task hub storage (identity-based) |
| `DURABLE_TASK_HUB` | **yes** | referenced as `%DURABLE_TASK_HUB%` in host.json (e.g. `hellodurable<env>`) |
| `RECONCILE_SCHEDULE` | **yes** | NCRONTAB, e.g. `0 */30 * * * *`; missing ⇒ the timer function fails to index |
| `ServiceBusConnection__fullyQualifiedNamespace` (+ `__credential`, `__clientId`) | yes | trigger connection |
| `SQL_CONNECTION_STRING`, `SQL_USE_AZURE_CREDENTIAL` | prod | as hello-orders-api; `STORAGE_MODE=memory` for local |
| `ORDERS_API_URL`, `INVENTORY_API_URL`, `PARTNER_API_URL` | prod | unset ⇒ status updates skipped / reservation simulated / payment simulated (approved) |
| `PAYMENT_TIMEOUT_SECONDS`, `DURABLE_HISTORY_RETENTION_DAYS`, `RECONCILE_WINDOW_HOURS` | no | 10 / 7 / 24 |
| `SERVICEBUS_FQDN` / `SERVICEBUS_CONNECTION_STRING`, `BATCH_ITEMS_QUEUE` | no | batch item enqueue (`batch-items`) |
| `FAULT_ACTIVITY_FAILURE_RATE` | lab | 0..1, default 0 (off): injected failures in Reserve/Charge/RecordFulfillment/ProcessItem |
| `AzureWebJobs.<Function>.Disabled` | no | e.g. disable `OrderEventsStarter` where no broker exists |
| `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `OTEL_SERVICE_NAME=hello-durable`, `OTEL_RESOURCE_ATTRIBUTES` | yes | set `OTEL_SERVICE_NAME` explicitly (host and worker resource detectors otherwise fall back to the site name) |
| OTLP endpoint variables | see below | |

Outbound HTTP: 3 s per attempt, 8 s total, 1 retry including POST (reserve/release/payments are idempotent by order id).

## host.json

`telemetryMode: OpenTelemetry` (host emits OTel), `extensions.durableTask.tracing` = `{"DistributedTracingEnabled": true, "Version": "V2"}`
([Learn](https://learn.microsoft.com/azure/durable-task/durable-functions/durable-functions-diagnostics#distributed-tracing)),
Azure Storage provider on `AzureWebJobsStorage`, `hubName: %DURABLE_TASK_HUB%`, inputs/outputs not traced,
`DurableTask.*` host categories at Warning. No `extensionBundle` (isolated worker uses NuGet extensions).

## Telemetry — verified behaviour and the decision you must make

Verified locally (Core Tools 4.15.2 + Azurite + OTLP/HTTP sink):

1. `Microsoft.Azure.Functions.Worker.OpenTelemetry` `UseFunctionsWorkerDefaults()` **stops worker `ILogger` output from
   being relayed to the host**, i.e. application logs vanish from the host log stream / `FunctionAppLogs`. It is therefore
   **off by default** (`FUNCTIONS_WORKER_OTEL_DEFAULTS=true` opts in). Worker spans still flow: the worker registers the
   `Microsoft.Azure.Functions.Worker`, `Microsoft.DurableTask`, `Hello.App`, HttpClient, SqlClient and Azure SDK sources itself.
2. The **host** only exports OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. In that mode it also emits the Durable V2
   spans (`orchestration:OrderProcessing`, `activity:ReserveInventory`, …) and the worker emits `Invoke` spans —
   **but the host also exports host + worker logs as OTLP logs**. The host.json filter
   `logging.OpenTelemetry.logLevel.default = None` (and the equivalent env vars) did **not** suppress them locally.
3. With only `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` / `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` set, the host exports nothing
   (no orchestration/activity spans); the worker exports its own spans/metrics; logs reach the host stream only.

Recommendation (ADR-0001 §10 — logs only via FunctionAppLogs → Event Hubs → Fluent Bit): set
`OTEL_EXPORTER_OTLP_ENDPOINT` (full Durable trace) **and** make the observability OTel gateway drop OTLP logs for this
service (no `logs` pipeline, or a filter on `service.name=hello-durable`). Alternative: per-signal endpoints only (no
duplicate logs, no host/orchestration spans).

Other telemetry: metrics `hello.workflows.completed{workflow,outcome}`, `hello.faults.injected{fault.type=activity_failure}`,
`hello.http.dependency.duration`; logs carry `order_id`, `workflow_instance_id`, `workflow_outcome`, `workflow_reason`.
In FunctionAppLogs the worker lines are host-formatted (not the ADR JSON line); correlation is via the host's
`operation id`/trace fields.

## Build, package, run

```bash
applications/dotnet/build.sh publish durable   # → .artifacts/durable/hello-durable-<ver>.zip (host.json at the zip root)
```

Local smoke (performed on 2026-10-09; Core Tools installed with `npm i -g azure-functions-core-tools@4 --unsafe-perm true`):

```bash
docker run -d -p 10000-10002:10000-10002 mcr.microsoft.com/azure-storage/azurite azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 --skipApiVersionCheck
dotnet publish applications/services/durable/src/Hello.Durable -c Release -o /tmp/durable
cp applications/services/durable/src/Hello.Durable/local.settings.sample.json /tmp/durable/local.settings.json
cd /tmp/durable && func host start --port 7071
curl -X POST localhost:7071/api/workflows/batch -d '{"items":12}'
```

Container: `docker build -f applications/services/durable/Dockerfile -t hello-durable:dev applications`
(base `mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0`, listens on 8080, sets
`WEBSITE_HOSTNAME=localhost:8080` because the Durable client binding requires it outside App Service). The Functions
base image runs as root.

## Test

```bash
cd applications/dotnet && dotnet test --project ../services/durable/tests/Hello.Durable.Tests
```

Orchestrators are tested with a hand-written `TaskOrchestrationContext` fake (honours `RetryPolicy` attempts,
controllable timers): happy path ordering, payment declined → compensation + Failed, retries exhausted → compensation,
retry then success, timeout (timer wins) → compensation, insufficient stock, reserve failure, batch fan-out/fan-in with a
failing item + enqueue, 50-item cap, reconciliation diff classification and persistence. Starter tests: deterministic
instance id, duplicate skip, invalid payload, consumer span with producer **link** (not parent).

## Limitations

- Timeout path: compensation runs immediately, but the instance stays `Running` until the outstanding (retried)
  `ChargePayment` attempts finish (observed ~20 s with an unreachable partner). A late successful charge is not refunded
  (partner-sim is idempotent by order id; a refund step is out of scope).
- Reconciliation reads at most 100 orders per run (orders-api page size).
- Service Bus trigger path not exercised locally (no broker/emulator here); the starter logic is unit-tested and the
  same code path was exercised through `POST /api/workflows/order`.
