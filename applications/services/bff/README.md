# hello-bff (.NET 10)

Owner: applications / .NET builder. Component: `svc-bff` (artifact: container image `hello-bff`).

Public entry point for the browser (hello-frontend). Thin backend-for-frontend: typed `HttpClient`s with the standard
resilience handler (no YARP), CORS for the SPA and Datadog RUM trace headers, per-IP fixed-window rate limiting and
optional Entra ID bearer authentication.

## Data boundary

None. The BFF owns no data; it forwards to hello-catalog-api, hello-orders-api, hello-inventory-api and the
hello-dbadapter instances.

## Endpoints

| Method | Path | Downstream |
|---|---|---|
| GET | `/api/catalog/products` | catalog `GET /products` |
| GET | `/api/catalog/products/{sku}` | catalog `GET /products/{sku}` |
| POST | `/api/orders` | orders `POST /orders` — forwards `Idempotency-Key` (generates a UUID when the browser sent none); returns the downstream 202 + order and `Idempotent-Replayed` |
| GET | `/api/orders?limit=20` | orders `GET /orders?limit=` (1..100) |
| GET | `/api/orders/{id}` | orders `GET /orders/{id}` |
| GET | `/api/inventory/{sku}` | inventory `GET /inventory/{sku}`; 503 problem when `INVENTORY_API_URL` is unset |
| GET | `/api/adapters` | JSON array `[{family, roundtrip_path}]` from `ADAPTERS_JSON` (adapter URLs are not exposed to the browser) |
| POST | `/api/adapters/{family}/roundtrip` | adapter `POST /roundtrip`; 404 problem for unknown family |
| GET | `/api/healthz`, `/api/version` (+ `/api/readyz`) | unauthenticated |
| GET | `/healthz`, `/readyz`, `/version` | probes (readiness has no owned dependencies → always ready) |
| POST/GET/DELETE | `/admin/faults` | lab fault injection |

Downstream responses (status, content type, body ≤ 1 MB) are passed through. Transport failures map to RFC 7807:
`dependency-timeout` 504, `dependency-unavailable` 503 (circuit open), `dependency-error` 502,
`dependency-not-configured` 503, `rate-limited` 429.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | 8080 | |
| `CATALOG_API_URL`, `ORDERS_API_URL`, `INVENTORY_API_URL` | — | downstream base URLs |
| `ADAPTERS_JSON` | `[]` | `[{"family":"sql","url":"http://hello-dbadapter-sql"}]` |
| `CORS_ALLOWED_ORIGINS` | none | comma list of SPA origins (exact match) |
| `AUTH_MODE` | `none` | `none` \| `entra` (JWT bearer on `/api/*` except healthz/version/readyz) |
| `ENTRA_TENANT_ID`, `ENTRA_AUDIENCE` | — | authority `https://login.microsoftonline.com/<tenant>/v2.0`; audiences `<aud>` and `api://<aud>`; v1 + v2 issuers |
| `RATE_LIMIT_PERMIT_LIMIT`, `RATE_LIMIT_WINDOW_SECONDS` | 100, 10 | fixed window per client IP; probes exempt |
| `FORWARDED_HEADERS_ENABLED` | false | honour `X-Forwarded-For/Proto` from private-range proxies (ingress/App Gateway) so rate limiting sees client IPs |
| common | | `DD_*`, `GIT_COMMIT`, `BUILD_TIME`, `OTEL_*`, `LOG_LEVEL`, `LOG_FILE_PATH`, `FAULTS_ENABLED`, `FAULT_TOKEN` |

CORS policy: methods GET/POST/OPTIONS; allowed headers `content-type, idempotency-key, traceparent, tracestate,
authorization, x-datadog-origin, x-datadog-parent-id, x-datadog-sampling-priority, x-datadog-trace-id, x-datadog-tags`;
exposed `traceparent, Idempotent-Replayed`; preflight cache 10 min. CORS runs first so error responses carry CORS headers.

Resilience per downstream: 5 s total, 2 s per attempt, 2 retries (exponential + jitter) for GET/HEAD/PUT/DELETE only
(POST never retried), circuit breaker (50 % failures over ≥30 s, min 10 calls, 15 s break). Adapter roundtrips: 20 s / 15 s, 1 retry for GET only.

## Telemetry

- Spans: server spans continue the browser's W3C context (RUM `allowedTracingUrls` with `tracecontext`); client spans per
  downstream call; response header `traceparent` for RUM ↔ APM linking.
- Metrics: `hello.http.dependency.duration{peer.service}`, ASP.NET Core (incl. rate-limiting), HttpClient, runtime.
- Logs: JSON (ADR-0001 §9). Polly resilience events (retries, timeouts, circuit state) are logged by `Polly`.

## Run locally / test

```bash
cd applications/dotnet
ORDERS_API_URL=http://localhost:8081 CORS_ALLOWED_ORIGINS=http://localhost:5173 PORT=8080 \
  dotnet run --project ../services/bff/src/Hello.Bff
dotnet test --project ../services/bff/tests/Hello.Bff.Tests
```

Tests (WebApplicationFactory + stub downstream handler): operational endpoints, CORS preflight with RUM headers and
origin rejection, `traceparent` exposure, POST forwarding with Idempotency-Key and trace continuity, GET retry vs POST
no-retry, inventory 503, adapters list/roundtrip/404, Entra mode 401, rate-limit 429, `dependency_timeout` fault → 504.

Container: `docker build -f applications/services/bff/Dockerfile -t hello-bff:dev applications` (chiseled, uid 1654).
