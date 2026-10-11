# Demo walkthrough: one order traced end to end

This walkthrough follows a single user action - **create an order in the browser** - through every hop of the
Enterprise Hello vertical slice (ADR-0001 section 9) and lists which spans, logs and metrics each hop emits and where
they arrive in Datadog. Service names, span names, attributes and tags are taken from the code; the Datadog side has
**not** been observed live (no organisation was available), so treat the "where it appears" column as the designed
path, verified locally only up to OTLP/HTTP sinks and a mock log intake.

Assumed deployment: profile `minimal` (BFF, orders and catalog on Container Apps, durable on Flex Consumption,
partner-sim on ACI). Differences for AKS are noted. Application diagram: [03-application](../diagrams/svg/03-application.svg);
telemetry diagram: [04-telemetry](../diagrams/svg/04-telemetry.svg).

## Before you start

* `deploy-durable` derives `ORDERS_API_URL` from the `deploy-core-aca` (or `deploy-core-aks`, unless the URL is
  Kubernetes-internal) contract, `INVENTORY_API_URL` from `deploy-appservice` (else the core contracts) and
  `PARTNER_API_URL` from `deploy-partner-sim`; `components.deploy-durable.*_api_url` override them. In `minimal` there is
  no inventory API, so the reservation is simulated. `deploy-jobs` gets `DURABLE_API_URL` from the `deploy-durable`
  contract the same way.
* `CORS_ALLOWED_ORIGINS` of the BFF must contain the SWA origin (two-pass, `deploy-core-aca` README).
* RUM needs `obs-prereqs` applied before `deploy-frontend` (client token + application id in `config.json`).

## Tags and log shape

Every signal carries the [tag policy](datadog-tagging.md) keys (`DD_ENV` / `DD_SERVICE` / `DD_VERSION` / `DD_TAGS` from
`observability/modules/instrumentation`; `OTEL_*` only for OpenTelemetry workloads such as hello-durable).

Team/domain/tier per service (`applications/deployments/modules/service-meta`): hello-frontend web/storefront/high,
hello-bff web/storefront/critical, hello-orders-api orders/orders/critical, hello-catalog-api catalog/catalog/high,
hello-durable fulfillment/fulfillment/critical, hello-partner-sim fulfillment/payments/low, hello-inventory-api
orders/inventory/high, hello-worker fulfillment/notifications/medium.

Every JSON log line has the ADR-0001 section 9 shape; `dd.trace_id` / `dd.span_id` link it to the trace.

## The journey

| # | Hop | Service (`service` tag) | Spans | Logs | Metrics |
|---|---|---|---|---|---|
| 1 | User opens `#/`, picks a product, submits the order form | `hello-frontend` (RUM) | RUM view + action + resource events; the fetch to the API origin carries W3C `traceparent` (`allowedTracingUrls`, `tracecontext` only, exact origin match) so the resource event gets `_dd.trace_id` | browser only | RUM (sessions sampled at `sessionSampleRate`, replay forced to 0) |
| 2 | `GET /api/catalog/products` then `POST /api/orders` with `Idempotency-Key` | `hello-bff` | ASP.NET Core server span continuing the browser trace; HttpClient client span per downstream; response header `traceparent` | JSON line per request; Polly retry/timeout/circuit events | `hello.http.dependency.duration{peer.service}`, ASP.NET Core, HttpClient, runtime |
| 3 | `POST /orders` (forwarded key, 5 s budget, POST never retried) | `hello-orders-api` | server span; HttpClient span to catalog; SqlClient spans (`microsoft.sql_server`); producer span **`send order-events`** (source `Hello.App`, `messaging.*` attributes); Azure SDK `ServiceBusSender.Send` | `order_id`, `sku`, `quantity`, `amount` | `hello.orders.created{order.status}`, `hello.idempotency.replays`, `hello.orders.publish_failures` on broker errors |
| 4 | price lookup `GET /products/{sku}` | `hello-catalog-api` | FastAPI server span; redis client span (cache-aside, header `X-Cache: HIT/MISS/BYPASS`); psycopg span on a miss | access log line + app lines | `hello.catalog.cache.requests{cache.result}` |
| 5 | insert into `orders.orders` / `orders.idempotency`, then publish `OrderCreated` to topic `order-events` (`MessageId = order_id`, application properties `traceparent`, `tracestate`) | `hello-orders-api` | (spans of step 3) | | |
| 6 | subscription `fulfillment` triggers `OrderEventsStarter` -> instance `order-{order_id}` | `hello-durable` | consumer span **`process order-events`** whose parent is the Functions invocation span and which carries a **span link** to the producer (not a parent) - the async hop starts a new trace | FunctionAppLogs (host-formatted lines, not the ADR JSON shape) | |
| 7 | `OrderProcessing` orchestration: `ReserveInventory` -> `UpdateOrderStatus(Reserved)` -> `ChargePayment` (raced against a `PAYMENT_TIMEOUT_SECONDS` timer, 3 attempts) -> `UpdateOrderStatus(Charged)` -> `RecordFulfillment` (SQL `MERGE` into `fulfillment.fulfillments`) -> `UpdateOrderStatus(Fulfilled)`; compensation `ReleaseInventory` on failure | `hello-durable` | Durable V2 spans from the host (`orchestration:OrderProcessing`, `activity:ReserveInventory`, ...) when `OTEL_EXPORTER_OTLP_ENDPOINT` is set; worker `Invoke` spans; HttpClient and SqlClient spans | `order_id`, `workflow_instance_id`, `workflow_outcome`, `workflow_reason` | `hello.workflow.completed{workflow,outcome}`, `hello.workflow.duration{workflow}` (ms) - emitted once by the final `RecordWorkflowOutcome` activity |
| 8 | `POST /payments` (idempotent by `order_id`) | `hello-partner-sim` | FastAPI server span | JSON lines | `hello.partner.payments{status}` |
| 9 | `PATCH /orders/{id}/status` (Reserved, Charged, Fulfilled / Failed) | `hello-orders-api` | server span + SqlClient | `from_status` / `to_status` | `hello.orders.status_transitions{order.status}` |
| 10 | browser polls `GET /api/orders/{id}` with backoff until `Fulfilled` / `Failed` and renders the timeline | `hello-frontend` -> `hello-bff` -> `hello-orders-api` | one short trace per poll | | |
| side (not in `minimal`) | subscription `notifications` -> `hello-worker` upserts table `notifications` (RowKey = order id) | `hello-worker` | **`servicebus.process`** (CONSUMER) in a new trace with a link to the producer | `/var/log/hello-worker/worker.log` on VMs, stdout on AKS | |
| side (not in `minimal`) | subscription `audit` -> `hello-functions` `audit` | `hello-functions` | `servicebus.process` linked to the producer | FunctionAppLogs | |
| side (`full` only) | subscription `archive` -> Logic Apps Standard writes the event to blob container `order-archive` | Logic App | - | WorkflowRuntime diagnostic logs | Azure integration platform metrics |

## Where each signal arrives

Package defaults per platform: [datadog-fleet-collection.md](datadog-fleet-collection.md#2-matrix-per-resource-type).
In `minimal`: BFF / orders / catalog logs, traces and DogStatsD metrics go through the serverless-init sidecar,
partner-sim through the ACI Agent sidecar, durable logs through FunctionAppLogs -> Event Hubs, and durable traces over
OTLP to the OTel gateway (which drops OTLP logs, so host logs are not duplicated). Logs pass the Observability Pipelines
Worker, whose tag processor fills missing policy tags and never overwrites them. On AKS the node Agent and SSI replace
the sidecars. Platform metrics come from the Azure integration, query samples from `obs-dbm` (ACI Agent in `minimal`).

## Checking it in Datadog

1. **RUM** -> Sessions -> filter `service:hello-frontend env:<env>` -> the order submission resource -> *View trace*.
2. **APM** -> trace of `hello-bff` `POST /api/orders` shows bff -> orders-api -> catalog-api (+ redis/psycopg) -> SQL -> `send order-events`.
3. Open the linked trace from the producer span: `process order-events` (hello-durable) -> orchestration / activity
   spans -> partner-sim `POST /payments` -> orders-api `PATCH`.
4. **Logs** -> `service:hello-orders-api @order_id:<id>`; pivot to the trace via `dd.trace_id`.
5. **Metrics** -> `hello.workflow.completed{workflow:OrderProcessing}` by `outcome` (the optional monitoring content's
   `workflow.failure_rate` monitor of hello-durable uses it).

Automated version of these checks: `observability/tools/verify/telemetry_verify.py` (checks `rum_resource_trace`,
`apm_journey`, `logs_pipeline`, `logs_trace_corr`, `logs_no_duplicates`, `required_tags`, `infra_metrics`), run by the
pipeline's Verify stage.

## Making it fail on purpose

See [fault-injection runbook](../runbooks/fault-injection.md): e.g. `dependency_timeout` on hello-bff produces 504s and
the `apm.error_rate` / `apm.http_5xx` monitors (optional monitoring content); `PARTNER_FAILURE_RATE` on partner-sim drives the durable retry and
compensation path (`outcome:compensated`).
