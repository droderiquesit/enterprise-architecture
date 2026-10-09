# eh-pr-reviewer — trusted Azure Function for automated PR review

Python 3.13, Azure Functions **v2 programming model**, Flex Consumption (infrastructure: `foundation/pr-reviewer`).
Review engine: `tools/review` (bundled into the package by `build.sh`). Guide and threat model:
[docs/guides/automated-pr-review.md](../../../docs/guides/automated-pr-review.md).

| Function | Trigger | What it does |
|---|---|---|
| `ado_webhook` | HTTP `POST /api/ado-webhook` (anonymous at Functions level) | HTTP Basic check in constant time against `WEBHOOK_SECRET` (DSV), payload allowlist (org / project / repository, event type), replay window + event-id cache → enqueue → `202`. Duplicate deliveries → `200 duplicate`. |
| `review_worker` | Storage queue `%REVIEW_QUEUE_NAME%`, identity connection `ReviewQueue` | per-PR blob lease → `tools.review.service.process` (reads the PR via REST, reviews, publishes threads / status `eh-review/policy` / vote) → re-check every `REVIEW_RECHECK_SECONDS` while the PR build is pending (max `REVIEW_MAX_RECHECKS`). Exceptions → host retry with visibility back-off, poison queue after 5 dequeues. |
| `healthz`, `readyz`, `version` | HTTP GET | liveness, configuration readiness (no secret values in output), build info. |

## Settings (set by foundation/pr-reviewer)

`ADO_ORGANIZATION`, `ADO_PROJECT`, `ADO_PROJECT_ID`, `ADO_REPOSITORY_IDS`, `ADO_ACCOUNT_IDS` (optional), `ADO_REVIEWER_ID`
(optional; else `connectionData`), `WEBHOOK_USERNAME`, `WEBHOOK_SECRET` (`dsv://…`), `WEBHOOK_SECRET_PREVIOUS` (rotation,
optional), `ANTHROPIC_API_KEY` (`dsv://…`, optional), `AZURE_CLIENT_ID`, `AzureWebJobsStorage__*` and `ReviewQueue__*`
(identity-based), `REVIEW_QUEUE_NAME`, `REVIEW_LOCK_CONTAINER_URI`, `DSV_TENANT`/`DSV_TLD`/`DSV_BASE_URL`, `DD_ENV`,
`DD_SERVICE=eh-pr-reviewer`, `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`. `dsv://` values are resolved in-process
at start-up by `hello_common.secrets.resolve_env()` with the Function's managed identity; an unresolved reference is never
accepted as a webhook secret.

Azure DevOps authentication: `ManagedIdentityCredential(client_id=AZURE_CLIENT_ID).get_token("499b84ac-1321-427f-aa17-267ca6975798/.default")`
(resource id of Azure DevOps, Microsoft Learn). `ADO_AUTH=static` is for the local fake server only.

## Build, test, run locally

```bash
applications/services/pr-reviewer/build.sh --zip /tmp/eh-pr-reviewer.zip      # staged package incl. tools/review + hello_common
python3.13 -m venv .venv && .venv/bin/pip install -r applications/services/pr-reviewer/requirements.txt pytest
.venv/bin/python -m pytest applications/services/pr-reviewer/tests tests/review
python3 tests/review/e2e_local.py        # fake Azure DevOps + real git branches -> docs/evidence/local/pr-review/
ruff check --config applications/python/ruff.toml applications/services/pr-reviewer tools/review tests/review
```

Logs are one JSON object per line (hello_common, ADR-0001 §9); request bodies, headers and secrets are never logged.
Status: **implemented / locally-verified** (fake Azure DevOps) — not deployed.
