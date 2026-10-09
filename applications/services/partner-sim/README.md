# hello-partner-sim

Simulated external payment provider (synthetic data only; no real payments). Hosted on Azure Container Instances.
**Data boundary:** none (bounded in-memory store, lost on restart by design).

| Method | Path | Notes |
|---|---|---|
| POST | `/payments` `{order_id, amount, currency?}` | 201 `{payment_id, order_id, amount, currency, status: approved\|declined, created_at, reference}`; idempotent by `order_id` (replay → 200 + `Idempotent-Replayed: true`; different amount → 409) |
| GET | `/payments/{payment_id}` | |
| GET | `/healthz` `/readyz` `/version`, `/admin/faults` | |

Lab knobs: `LATENCY_MS_MEAN` (150), `LATENCY_MS_JITTER` (50), `PARTNER_FAILURE_RATE` (transient 503, not recorded),
`PARTNER_DECLINE_RATE`, `PARTNER_DECLINE_ABOVE` (10000), `PARTNER_MAX_PAYMENTS` (100000) + common variables.
Telemetry: server spans, JSON logs, metric `hello.partner.payments{status}`.
Run: `docker run -p 8080:8080 hello-partner-sim:dev`. Tests: `pytest` (5 unit).
