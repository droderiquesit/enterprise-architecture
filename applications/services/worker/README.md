# hello-worker

Long-running consumer of Service Bus topic `order-events` / subscription `notifications`. **Data boundary:** Azure
Table Storage table `notifications` (PartitionKey `order`, RowKey = order id → idempotent upsert; duplicates and
redeliveries converge on one row). Runs on VM/VMSS (systemd), AKS and confidential VMs.

## Behaviour
* `azure-servicebus` async receiver (PEEK_LOCK, prefetch) with `AutoLockRenewer`; bounded concurrency (`MAX_CONCURRENCY`).
* One span per message named **`servicebus.process`** (kind CONSUMER) in a *new* trace with a **span link** to the
  producer `traceparent` from `application_properties` (falls back to `Diagnostic-Id`) — not a parent.
* Poison messages (invalid JSON / missing `order_id`) → dead-letter `PoisonMessage`; transient failures → bounded
  backoff then abandon; dead-letter `MaxDeliveryAttemptsExceeded` at `MAX_DELIVERY_ATTEMPTS`.
* SIGTERM/SIGINT: stop receiving, drain in-flight (`SHUTDOWN_GRACE_SECONDS`), close, flush telemetry, exit 0.
* Health HTTP on `PORT` (8081): `/healthz`, `/readyz` (receive loop alive + source healthy + sink ping), `/version`.

## Configuration
See `src/hello_worker/settings.py` docstring: `MESSAGING_MODE` (servicebus|memory), `SERVICEBUS_FQDN` (managed
identity) or `SERVICEBUS_CONNECTION_STRING` (emulator), `SB_TOPIC`, `SB_SUBSCRIPTION`, `SB_QUEUE`, `MAX_CONCURRENCY`,
`RECEIVE_BATCH`, `RECEIVE_WAIT_SECONDS`, `PREFETCH`, `MAX_DELIVERY_ATTEMPTS`, `LOCK_RENEW_MAX_SECONDS`,
`PROCESSING_TIMEOUT_SECONDS`, `RETRY_DELAY_BASE_SECONDS`, `SHUTDOWN_GRACE_SECONDS`, `TABLE_MODE` (table|memory),
`TABLES_ENDPOINT` / `TABLES_CONNECTION_STRING`, `TABLE_NAME`, plus the common variables.
RBAC needed: *Azure Service Bus Data Receiver* on the subscription, *Storage Table Data Contributor* on the table.

## VM packaging (`deploy/vm/`)
`build.sh` produces `.artifacts/worker/hello-worker-<ver>-vm.zip` = offline wheelhouse (linux x86_64, cp313, incl.
hello-worker + hello-common wheels), `requirements.txt`, `VERSION`, `deploy/{install.sh,hello-worker.service,hello-worker.env.example}`.
The run-command deployer calls:
```bash
bash install.sh <package-url|path> [--env-file /path/hello-worker.env]   # PACKAGE_AUTH=msi for SAS-less blob URLs (IMDS token)
bash install.sh --rollback
```
install.sh: ensures Python 3.13 (deadsnakes when `INSTALL_PYTHON=1` and missing), creates system user
`hello-worker`, unpacks to `/opt/hello-worker/releases/<ver>-<ts>` with its own venv (`pip --no-index`), writes
`/etc/hello-worker/hello-worker.env` (0640), installs the hardened systemd unit, swaps `/opt/hello-worker/current`
atomically, restarts, probes `/healthz` and **rolls back automatically** on failure; keeps 3 releases.
Logs: journald + `/var/log/hello-worker/worker.log` (`LOG_FILE_PATH`, tailed by the host Datadog Agent; Fluent Bit with
`log_pipeline = fluent_bit_direct`); OTLP to the local
Datadog Agent (`localhost:4317`).

## Tests
`pytest` (6 unit: link-not-parent, idempotent upsert, poison DLQ, retry→DLQ, fault retry, bounded concurrency,
process SIGTERM drain + LOG_FILE_PATH); `pytest -m integration` (1: official Service Bus emulator + SQL Server +
Azurite Tables, producer → worker → table row + DLQ assertion). install.sh was exercised offline in a
`python:3.13-slim` container (install, run as `hello-worker`, SIGTERM exit 0, upgrade, rollback) with
`SKIP_SYSTEMD=1`; systemd itself was not exercised.
