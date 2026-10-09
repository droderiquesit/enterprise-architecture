# Local end-to-end integration evidence (LATEST)

Status label: **locally-verified (docker, mock Datadog intake)**. This is NOT Datadog-verified and nothing was deployed: every Datadog endpoint is the
local mock intake (`observability/tests/transport/mock_intake`), Azure Service Bus/Storage are the official emulators,
Cosmos DB is replaced by hello-inventory-api `STORAGE_MODE=memory`, Delinea DSV is `tools/secrets/mock_dsv.py`
(apps: `DSV_AUTH=client_credentials`; Fluent Bit / OTel gateway: dsv-fetch init services). See `tests/integration/README.md`.

- Run: `20261009T213848Z` (UTC 2026-10-09T21:38:48+00:00 -> 2026-10-09T21:41:08+00:00), git HEAD `3eb963c`, images `:0.1.0-e2e` built from source (revision label -> app source diff vs worktree: {'hello-bff:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-orders-api:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-inventory-api:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-durable:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-catalog-api:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-dbadapter:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-worker:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-partner-sim:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)', 'hello-frontend:0.1.0-e2e': '3c5834e-dirty:  25 files changed, 2169 insertions(+), 9 deletions(-)'})
- Command: `python3 tests/integration/run_e2e.py`
- Order: `1e318a6f-48d2-466e-a37b-c2ec2b272105` final status `Fulfilled`; browser trace `00000000000000006fcd385a779328f1`
- Totals: {'pass': 12}

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | RUM view + resource + action events captured (Playwright route -> mock intake) | pass | [rum-events.sample.json](20261009T213848Z/rum-events.sample.json) |
| 2 | Browser traceparent trace_id in hello-bff, hello-orders-api, hello-catalog-api spans + DB client span | pass | [trace-journey.json](20261009T213848Z/trace-journey.json) |
| 3 | hello-durable orchestration/activity spans exist and are tied to the order's trace | pass | [durable-workflow.json](20261009T213848Z/durable-workflow.json) |
| 4 | hello-worker servicebus.process consumer span links to the producer span | pass | [worker-consumer.json](20261009T213848Z/worker-consumer.json) |
| 5 | Logs of every app arrive via Fluent Bit with ddsource/service/env/version + pipeline tag; journey logs carry the trace_id | pass | [logs-sample.json](20261009T213848Z/logs-sample.json) |
| 6 | No duplicates: unique marker log count == 1 per service; no duplicated events/spans | pass | [duplicates.json](20261009T213848Z/duplicates.json) |
| 7 | Required tags / resource attributes on spans, metrics, logs and RUM | pass | [tags.json](20261009T213848Z/tags.json) |
| 8 | Secret redaction at the intake (app path + Fluent Bit transport path) | pass | [redaction.json](20261009T213848Z/redaction.json) |
| 9 | Fault injection: 201 + BFF errors + recovery after expiry; wrong token 403; FAULTS_ENABLED=false 404 | pass | [faults.json](20261009T213848Z/faults.json) |
| 10 | Idempotency-Key on POST /api/orders replays the same order | pass | [idempotency.json](20261009T213848Z/idempotency.json) |
| 11 | OTel gateway datadog exporter delivers traces/metrics to the (mock) intake; OTLP logs not forwarded | pass | [intake-requests.json](20261009T213848Z/intake-requests.json) |
| 12 | Secrets resolved from DSV (mock), no secret value in logs/intake | pass | [secrets-dsv.json](20261009T213848Z/secrets-dsv.json) |

Known gaps (not covered locally): Cosmos DB (memory store), Entra ID auth (AUTH_MODE=none, SQL/PG password auth),
Event Hubs/Kafka aggregator path for App Service/Functions logs (covered separately by observability/tests/transport),
Azure Monitor diagnostic settings, real Datadog ingestion/indexing/UI (mock intake only), real DSV + the managed-identity
azure grant (mock DSV with client_credentials; the azure grant is unit-tested against the mock with fake Entra tokens).
Additional evidence in this run directory (same session, 2026-10-09):

- [dsv-fetch-docker-smoke.json](20261009T213848Z/dsv-fetch-docker-smoke.json) — `observability/images/dsv-fetch/tests/docker_smoke.py`
  on an `--internal` docker network (mock DSV, fake IMDS, header-hashing intake): dsv-fetch writes 0400 files on tmpfs
  (read-only rootfs, uid 65532, azure grant via IMDS); Fluent Bit 5.1.3 resolves `${DD_API_KEY}` from an included
  `env:` file (also over a conflicting process env var, and as uid 65532); OTel collector-contrib 0.162.0 resolves
  `${file:/dsv-secrets/DD_API_KEY}`; the Agent backend protocol round trip; Datadog Agent 7.84.2 with
  `secret_backend_command` = `dsv-fetch install` copy (0500 root) sends the DSV-resolved key. All 5 checks `ok`.
