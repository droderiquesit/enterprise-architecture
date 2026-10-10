# Local end-to-end integration evidence (LATEST)

Status label: **locally-verified (docker, mock Datadog intake)**. This is NOT Datadog-verified and nothing was deployed: every Datadog endpoint is the
local mock intake (`observability/tests/transport/mock_intake`), Azure Service Bus/Storage are the official emulators,
Cosmos DB is replaced by hello-inventory-api `STORAGE_MODE=memory`, Delinea DSV is `tools/secrets/mock_dsv.py`
(apps: `DSV_AUTH=client_credentials`; Fluent Bit / OTel gateway: dsv-fetch init services). See `tests/integration/README.md`.

- Run: `20261010T021945Z` (UTC 2026-10-10T02:19:45+00:00 -> 2026-10-10T02:22:28+00:00), git HEAD `478f20c`, images `:0.1.0-e2e` built from source (revision label -> app source diff vs worktree: {'hello-bff:0.1.0-e2e': '127868d-dirty:  21 files changed, 6726 insertions(+), 15 deletions(-)', 'hello-orders-api:0.1.0-e2e': '127868d-dirty:  21 files changed, 6726 insertions(+), 15 deletions(-)', 'hello-inventory-api:0.1.0-e2e': '127868d-dirty:  21 files changed, 6726 insertions(+), 15 deletions(-)', 'hello-durable:0.1.0-e2e': '127868d-dirty:  21 files changed, 6726 insertions(+), 15 deletions(-)', 'hello-catalog-api:0.1.0-e2e': '5c769ae-dirty:  30 files changed, 6777 insertions(+), 25 deletions(-)', 'hello-dbadapter:0.1.0-e2e': '5c769ae-dirty:  30 files changed, 6777 insertions(+), 25 deletions(-)', 'hello-worker:0.1.0-e2e': '5c769ae-dirty:  30 files changed, 6777 insertions(+), 25 deletions(-)', 'hello-partner-sim:0.1.0-e2e': '5c769ae-dirty:  30 files changed, 6777 insertions(+), 25 deletions(-)', 'hello-frontend:0.1.0-e2e': '478f20c-dirty:  3 files changed, 37 insertions(+), 3 deletions(-)'})
- Command: `python3 tests/integration/run_e2e.py`
- Order: `6cf50539-d018-4c5b-abbe-7e3e3341fa55` final status `Fulfilled`; browser trace `0000000000000000ed9743e37976f10d`
- Totals: {'pass': 12}

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | RUM view + resource + action events captured (Playwright route -> mock intake) | pass | [rum-events.sample.json](20261010T021945Z/rum-events.sample.json) |
| 2 | Browser traceparent trace_id in hello-bff, hello-orders-api, hello-catalog-api spans + DB client span | pass | [trace-journey.json](20261010T021945Z/trace-journey.json) |
| 3 | hello-durable orchestration/activity spans exist and are tied to the order's trace | pass | [durable-workflow.json](20261010T021945Z/durable-workflow.json) |
| 4 | hello-worker servicebus.process consumer span links to the producer span | pass | [worker-consumer.json](20261010T021945Z/worker-consumer.json) |
| 5 | Logs of every app arrive via Fluent Bit with ddsource/service/env/version + pipeline tag; journey logs carry the trace_id | pass | [logs-sample.json](20261010T021945Z/logs-sample.json) |
| 6 | No duplicates: unique marker log count == 1 per service; no duplicated events/spans | pass | [duplicates.json](20261010T021945Z/duplicates.json) |
| 7 | Required tags / resource attributes on spans, metrics, logs and RUM | pass | [tags.json](20261010T021945Z/tags.json) |
| 8 | Secret redaction at the intake (app path + Fluent Bit transport path) | pass | [redaction.json](20261010T021945Z/redaction.json) |
| 9 | Fault injection: 201 + BFF errors + recovery after expiry; wrong token 403; FAULTS_ENABLED=false 404 | pass | [faults.json](20261010T021945Z/faults.json) |
| 10 | Idempotency-Key on POST /api/orders replays the same order | pass | [idempotency.json](20261010T021945Z/idempotency.json) |
| 11 | OTel gateway datadog exporter delivers traces/metrics to the (mock) intake; OTLP logs not forwarded | pass | [intake-requests.json](20261010T021945Z/intake-requests.json) |
| 12 | Secrets resolved from DSV (mock), no secret value in logs/intake | pass | [secrets-dsv.json](20261010T021945Z/secrets-dsv.json) |

Known gaps (not covered locally): Cosmos DB (memory store), Entra ID auth (AUTH_MODE=none, SQL/PG password auth),
Event Hubs/Kafka aggregator path for App Service/Functions logs (covered separately by observability/tests/transport),
Azure Monitor diagnostic settings, real Datadog ingestion/indexing/UI (mock intake only), real DSV + the managed-identity
azure grant (mock DSV with client_credentials; the azure grant is unit-tested against the mock with fake Entra tokens).
