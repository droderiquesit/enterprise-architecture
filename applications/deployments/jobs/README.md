# deploy-jobs — Container Apps jobs and Azure Batch submission

- **Owner**: applications layer. **Status**: implemented (mock tests); `scripts/submit-batch-job.sh` syntax-checked only.
- **Jobs** (`azurerm_container_app_job`, identity `hello-jobs` / `hello-traffic`, ACR pull by identity):
  `seed` (manual, `python -m hello_jobs seed`), `reconcile` (schedule `settings.reconcile_cron`, `reconcile-trigger`),
  `batchitems` (event-driven, KEDA `azure-servicebus` scaler on queue `batch-items`, **authenticated with the user-assigned
  identity** via `rules.identity_id` — no connection string; `process-batch-items`), `traffic` (schedule, `hello-traffic`,
  bounded: `TRAFFIC_DURATION_SECONDS` ≤ 600, replica timeout = duration + 120 s; created only when deploy-frontend exists).
- **Batch**: jobs are runtime objects, not Terraform. `scripts/submit-batch-job.sh --contract <deploy-jobs contract>` creates
  job `hello-jobs-daily-aggregate` on the platform-batch pool and an idempotent task `daily-aggregate-<date>` whose
  resource file is the svc-jobs package fetched by the node with the pool identity (`identityReference`, no SAS),
  sha256-checked, then `run.sh daily-aggregate`; waits (bounded) for completion.
- **Consumed contracts**: platform-containerapps, platform-shared, platform-messaging, platform-db-sql, obs-telemetry-transport,
  foundation-identity; optional platform-batch, deploy-core-aks/deploy-core-aca (catalog/orders URLs, API origin; AKS
  `*.svc.cluster.local` URLs are ignored — not resolvable from ACA), deploy-frontend, deploy-durable
  (`function_app.hostname` → `DURABLE_API_URL` of the reconcile job; `settings.durable_api_url` overrides).
- **Produced contract**: `deploy-jobs`: `jobs.<name>.{id,trigger,schedule,...}` (monitoring uses `jobs.seed.id`), `batch`, `deploy_steps[batch-job]`.

## Logs
Jobs run to completion, so **no Fluent Bit sidecar** (it would keep executions running until timeout); stdout JSON logs
are collected through the environment's `ContainerAppConsoleLogs` diagnostic setting (obs-diagnostics → Event Hubs →
Fluent Bit aggregator, allow-list `aca_console_allow`).

Batch (ADR-0001 §13): the contract's `batch.job_preparation` carries the observability-published Fluent Bit setup
(`obs-telemetry-transport` `batch_log_setup`) plus `EH_IDENTITY_CLIENT_ID` (pool identity, needs Key Vault Secrets User
on `datadog-api-key`) and `EH_LOG_PATHS`. `submit-batch-job.sh` creates the job with that **job preparation task**
(elevated, `waitForSuccess`, re-run after reboot, script sha256-checked on the node), which installs Fluent Bit 5.1.3
as `fluent-bit-eh.service` tailing the tasks' `stdout.txt`. A job created earlier keeps its preparation task; the script
warns when the contract's setup differs (delete the idle job to pick it up).

## Settings
`reconcile_cron`, `traffic_cron`, `traffic.{enabled,rps (0.2),duration_seconds (300),browser_journeys}`,
`batch_processor.{enabled,max_executions (3),messages_per_job,polling_seconds}`, `durable_api_url`, `orders_api_url`,
`adapters`, `result_tables_endpoint`.

## Rollback / smoke
Previous digests; Batch re-submit with the previous package. Smoke: `scripts/smoke.sh --jobs` starts `seed` and waits for `Succeeded`.

## Cost
Consumption jobs billed per execution second: traffic 1 vCPU × 7 min × 48/day ≈ $15/month (disable or slow the cron to reduce).

Docs: https://learn.microsoft.com/azure/container-apps/jobs , https://learn.microsoft.com/azure/container-apps/tutorial-event-driven-jobs ,
https://keda.sh/docs/latest/scalers/azure-service-bus/ , https://learn.microsoft.com/azure/batch/managed-identity-pools
