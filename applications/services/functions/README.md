# hello-functions

Azure Functions, **Python v2 programming model** (`function_app.py`), Python 3.13.
**Data boundary:** audit entries in Azure Confidential Ledger collection `order-audit` (or Table Storage `audit`
fallback). Disable any function per hosting plan with app setting `AzureWebJobs.<name>.Disabled=true`.

| Function | Trigger | Notes |
|---|---|---|
| `audit` | Service Bus topic `order-events` / subscription `audit`, connection `ServiceBusConnection` | identity-based: `ServiceBusConnection__fullyQualifiedNamespace=<ns>.servicebus.windows.net`, `ServiceBusConnection__credential=managedidentity`, `ServiceBusConnection__clientId=<uami client id>`; `AUDIT_SINK=ledger\|table\|log`; span `servicebus.process` linked to the producer |
| `cache_warmer` | timer `0 */5 * * * *` | GET catalog `/products` then each `/products/{sku}` (fills Redis cache-aside) |
| `quote` | HTTP GET `/api/quote?sku=&quantity=` (anonymous; private ingress only) | price from catalog `price`/`unit_price`, problem+json errors (400/404/502/504) |

Settings: `CATALOG_API_URL`, `AUDIT_SINK`, `LEDGER_ENDPOINT`, `LEDGER_COLLECTION`, `TABLES_ENDPOINT`/`TABLES_CONNECTION_STRING`,
`AUDIT_TABLE`, `AzureWebJobsStorage__accountName` (identity-based host storage), common variables.

## OpenTelemetry → Datadog (verified against Microsoft Learn "Use OpenTelemetry with Azure Functions", Python)
* `host.json`: `"telemetryMode": "OpenTelemetry"` (host emits OTel).
* App settings: `OTEL_EXPORTER_OTLP_ENDPOINT` (observability OTel gateway), optional `OTEL_EXPORTER_OTLP_PROTOCOL`,
  `PYTHON_ENABLE_OPENTELEMETRY=true`; **no** `APPLICATIONINSIGHTS_CONNECTION_STRING`.
* Code: `hello_functions.bootstrap` configures the OTel SDK (opentelemetry-sdk + OTLP exporters + logging
  instrumentation, as the doc's "OTLP Exporter" tab requires) and JSON logging while keeping the worker's handler.
* **Finding:** with only `PYTHON_ENABLE_OPENTELEMETRY=true`, the Python 3.13 worker in
  `mcr.microsoft.com/azure-functions/python:4-python3.13` (digest b3faff84…) failed every invocation with
  `'NoneType' object has no attribute 'extract'` (its trace-context propagator is only initialised on the Azure
  Monitor path). `bootstrap._ensure_worker_propagator()` calls the worker's own initialiser; verified in the
  container (quote returned 200 against a catalog container).
* `host.json` extension bundle `[4.0.0, 5.0.0)` (current Microsoft Learn guidance).

## `TELEMETRY_SDK=datadog` (not the default here)
`hello_common` supports it (no OTel SDK; `ddtrace` from the image, imported via `ddtrace.auto`; if the
`datadog-serverless-compat` package is installed its `start()` runs first, as Datadog's Python Functions guide
prescribes, triggered by `FUNCTIONS_WORKER_RUNTIME`). It is **not** enabled for hello-functions: `datadog-serverless-compat`
is not a dependency, the guide requires `DD_API_KEY` as an app setting, and in this model `azure.functions` is imported by
`function_app.py` before `hello_common` (ddtrace still patches already-imported modules, but this ordering is unverified on
Azure). Keep `TELEMETRY_SDK` unset (otel) and `PYTHON_ENABLE_OPENTELEMETRY=true` until verified on a deployed app; in
datadog mode set `PYTHON_ENABLE_OPENTELEMETRY=false`.

## Packaging
* Zip (Flex Consumption / Premium / Dedicated): `.artifacts/functions/hello-functions-<ver>.zip` with dependencies
  pre-installed in `.python_packages/lib/site-packages` (linux x64, cp313) and `hello_common/` vendored at the root
  — deploy without remote build.
* Container (Functions on Container Apps): `Dockerfile` from `mcr.microsoft.com/azure-functions/python:4-python3.13`
  (pinned digest), runs as non-root uid 10001.

Tests: `pytest` (7 unit: function indexing/bindings, audit link, sinks, cache warmer, quote, host.json).
