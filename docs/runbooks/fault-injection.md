# Runbook: fault injection (lab only)

Fault injection exists to exercise monitors, runbooks and the durable compensation path. It is **authenticated,
limited, auto-expiring and disabled by default** (ADR-0001 section 9). Implementations:
[`hello_common/faults.py`](../../applications/shared/python/hello_common/src/hello_common/faults.py) (Python services)
and `FaultInjectionMiddleware` / `FaultState` in `applications/shared/dotnet` (.NET services). Verified by unit tests
(token checks, expiry with a fake clock, fault effects); never run against a deployed environment.

## Safety properties

| Property | Implementation |
|---|---|
| Disabled by default | `FAULTS_ENABLED` defaults to `false`; every deployment root that exposes `settings.faults_enabled` defaults it to `false` (8 roots; `frontend`, `jobs`, `logicapps`, `specialized` have no fault setting) and `applications/deployments/modules/app-env` maps it to `FAULTS_ENABLED`. While disabled, `/admin/faults` answers **404** (looks absent) |
| Authenticated | header `X-Fault-Token` compared in constant time (`hmac.compare_digest` / constant-time SHA-256 compare) with `FAULT_TOKEN`; missing/wrong token -> 403; **unset `FAULT_TOKEN` fails closed** (403) |
| Token storage | Key Vault secret `fault-token` (generated with `set-secrets.sh <vault> generate fault-token`), injected as a Key Vault reference / CSI secret; never in contracts. Exception: ACI partner-sim reads it at plan time (state) |
| Limited | types `http_500`, `latency`, `db_error`, `dependency_timeout`; `rate` 0..1; probes (`/healthz`, `/readyz`, `/version`) and admin routes are exempt |
| Auto-expiring | `duration_seconds` 1..900; faults expire on their own and do not survive a restart; `DELETE /admin/faults` clears all |
| Not in existing environments | `observability/examples/existing-environment` has `fault_injection_enabled = false` with a validation that rejects `true`, and the instrumentation output sets `FAULTS_ENABLED=false` |

Durable workflow and partner faults are separate, settings-driven knobs (no HTTP endpoint):

| Knob | Root setting | Effect |
|---|---|---|
| `FAULT_ACTIVITY_FAILURE_RATE` | `deploy-durable` `activity_failure_rate` (set only when `faults_enabled = true`) | injected failures in Reserve / Charge / RecordFulfillment / ProcessItem activities -> retries, compensation, `hello.faults.injected{fault.type=activity_failure}` |
| `PARTNER_FAILURE_RATE` | `deploy-partner-sim` `partner_failure_rate` (default 0, validated 0..1) | transient 503 from `/payments` (not recorded) |
| `PARTNER_DECLINE_RATE`, `PARTNER_DECLINE_ABOVE` | partner-sim env | declined payments -> `Failed` orders with compensation |

## Procedure

1. Enable for one service: `components.<deploy root>.faults_enabled: true` in `environments/<env>/environment.yaml`
   -> PR -> pipeline apply (approval on `lab-<env>`). Make sure `fault-token` exists in Key Vault.
2. From a host that reaches the service (internal ingress for everything except the BFF):
   ```bash
   TOKEN=$(az keyvault secret show --vault-name <vault> -n fault-token --query value -o tsv)   # VNet host
   curl -sS -X POST https://<service>/admin/faults -H "X-Fault-Token: $TOKEN" -H 'content-type: application/json' \
     -d '{"type":"dependency_timeout","rate":0.5,"duration_seconds":300}'
   curl -sS https://<service>/admin/faults -H "X-Fault-Token: $TOKEN"          # active faults
   curl -sS -X DELETE https://<service>/admin/faults -H "X-Fault-Token: $TOKEN" # stop early
   ```
   For the BFF the path is `/admin/faults` on its public origin; `/api/*` routes are not used for admin.
3. Observe: `hello.faults.injected{fault.type}`, the service's `apm.error_rate` / `apm.http_5xx` / `apm.latency_p95`
   monitors ([alert runbooks](alerts/README.md)), and the journey in [demo-walkthrough.md](../guides/demo-walkthrough.md).
4. Disable again: `faults_enabled: false` and apply. Rotate `fault-token` if it was shared
   ([secret rotation](secret-rotation.md)).

| Fault | Typical result |
|---|---|
| `http_500` | 500 problem responses at `rate` |
| `latency` | `latency_ms` added before handling |
| `db_error` | data layer returns 503 (`orders-api`, `catalog-api`, `inventory-api`) |
| `dependency_timeout` | outbound calls hang until the resilience timeout -> 504 from the caller (BFF maps to `dependency-timeout`) |
