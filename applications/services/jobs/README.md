# hello-jobs

CLI jobs: `python -m hello_jobs <seed|reconcile-trigger|process-batch-items|daily-aggregate>` — one root span per
run, JSON logs, summary log line, exit 0/1 (2 = usage), telemetry flushed before exit.
**Data boundary:** batch-item results in Table Storage `batchitems` (PartitionKey batch id, RowKey item id;
idempotent); daily aggregates as JSON files/blobs. (Reconciliation summaries are written by hello-durable.)

| Command | Hosting | What it does |
|---|---|---|
| `seed` | ACA job (manual) | POST `/seed` on catalog (`CATALOG_API_URL`), inventory (`INVENTORY_API_URL/inventory/seed`), adapters (`ADAPTERS_JSON`) with `Idempotency-Key` |
| `reconcile-trigger` | ACA job (scheduled) | POST `{DURABLE_API_URL}/api/workflows/reconciliation` (`x-functions-key` from `DURABLE_FUNCTION_KEY`, a Delinea DSV reference `dsv://…`, resolved at start-up by hello_common) |
| `process-batch-items` | ACA job (event-driven, KEDA azure-servicebus on `batch-items`) | receive ≤ `BATCH_MAX_MESSAGES` (50) within `BATCH_MAX_SECONDS` (60), exit when drained; span `servicebus.process` per message linked to producer; poison → DLQ; `RESULT_SINK=table\|log\|memory` |
| `daily-aggregate` | Azure Batch (zip + `run.sh`) and ACA | GET `{ORDERS_API_URL}/orders?since=<day>&limit=100`, aggregate per sku/status for `AGGREGATE_DATE` (default yesterday UTC), write `daily-aggregate-<date>.json` to `OUTPUT_PATH` (`$AZ_BATCH_TASK_WORKING_DIR`), optional upload to `AGGREGATE_BLOB_ACCOUNT_URL`/`AGGREGATE_BLOB_CONTAINER` |

Other variables: `MESSAGING_MODE`, `SERVICEBUS_FQDN`/`SERVICEBUS_CONNECTION_STRING`, `SB_QUEUE`, `MAX_DELIVERY_ATTEMPTS`,
`TABLES_ENDPOINT`/`TABLES_CONNECTION_STRING`, `RESULT_TABLE`, `ORDERS_PAGE_LIMIT`, common variables.

## Azure Batch package
`.artifacts/jobs/hello-jobs-<ver>-batch.zip` (offline wheelhouse + `run.sh` + `requirements.txt` + `VERSION`).
Task command line: `/bin/bash -c '"$AZ_BATCH_APP_PACKAGE_hello_jobs"/run.sh daily-aggregate'`. `run.sh` builds a
venv once per node/version under `$AZ_BATCH_NODE_SHARED_DIR` (flock-protected). The pool must provide
`python3.13` (start task) — verified offline in a `python:3.13-slim` container.

## Tests
`pytest` (8 unit), `pytest -m integration` (1: Service Bus emulator queue `batch-items` + Azurite Tables).
