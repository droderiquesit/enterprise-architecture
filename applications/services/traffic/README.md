# hello-traffic

Controlled synthetic traffic generator (ACA scheduled job). One bounded run per execution:
`TRAFFIC_BROWSER_JOURNEYS` (default 2) Playwright **Chromium** journeys through the real frontend (products →
order → wait for `Fulfilled`/`Failed`; the page's own Datadog RUM records them) and API journeys at `TRAFFIC_RPS`
(default 0.2/s) for `TRAFFIC_DURATION_SECONDS` (≤ 600) against hello-bff (list/get product, POST order with
`Idempotency-Key`, poll status, optional adapter roundtrip). Requests carry `User-Agent: hello-traffic/<ver>` and
`X-Synthetic: hello-traffic`; W3C `traceparent` via httpx instrumentation. **Data boundary:** none.

Variables: `FRONTEND_URL`, `API_BASE_URL` (default: `apiBaseUrl` from `FRONTEND_URL/config.json`), `TRAFFIC_RPS`,
`TRAFFIC_DURATION_SECONDS`, `TRAFFIC_BROWSER_JOURNEYS`, `TRAFFIC_ORDER_TIMEOUT_SECONDS`, `TRAFFIC_MAX_ERROR_RATIO`
(exit 1 above it), `TRAFFIC_SKUS`, `TRAFFIC_ROUNDTRIP_ADAPTERS`, `PW_CHROMIUM_EXECUTABLE` (override), common.
Telemetry: root span per journey (`journey api|browser`), metrics `hello.traffic.journeys{journey,outcome}` and
`hello.traffic.journey.duration`.

Image: `mcr.microsoft.com/playwright/python:v1.63.0-noble` (pinned by digest, same version as the `playwright`
package so bundled browsers match). That base ships Python 3.12, so the Dockerfile installs CPython 3.13 with a
pinned `uv` (0.12.24) and runs the app on 3.13 as `pwuser`. Image size ≈ 3.5 GB (browsers).

Tests: `pytest` (5 unit); `pytest -m integration` (2: real Chromium through the **built frontend bundle** served
locally with a fake BFF over HTTP — full browser journey to `Fulfilled`; API journey over HTTP asserting
`traceparent`). Locally Chromium came from `/opt/pw-browsers` (Playwright 1.56 build) via `PW_CHROMIUM_EXECUTABLE`
because browser downloads are blocked in the sandbox.
