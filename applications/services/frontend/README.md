# hello-frontend

React 19.3 + TypeScript 5.9 + Vite 8.3 single-page app with Datadog Browser RUM 7.15. Static; primary host
Azure Static Web Apps, nginx container variant for ACA/AKS. **Data boundary:** none (browser).

## Pages (hash routing)
`#/` products (GET `/api/catalog/products`) + create-order form (POST `/api/orders` with `Idempotency-Key`, one key
per attempt, reused on retry) · `#/orders/<id>` status timeline (polls `/api/orders/{id}` with backoff until
`Fulfilled`/`Failed`) · `#/adapters` roundtrip panel (GET `/api/adapters` → `[{family, roundtrip_path}]`, POST
`roundtrip_path`) · footer with frontend version, env, BFF `/api/version`, RUM on/off. Heading text
"Enterprise Hello" is always visible (asserted by the Datadog browser synthetic). `data-testid` attributes are a
contract with hello-traffic.

## Runtime configuration — `/config.json` (loaded **before** RUM init and before the first API call)
```json
{"env":"dev","service":"hello-frontend","version":"1.0.0","apiBaseUrl":"https://bff.example.com",
 "rum":{"applicationId":"<uuid>","clientToken":"pub...","site":"datadoghq.com","sessionSampleRate":100,
        "sessionReplaySampleRate":0,"traceSampleRate":100,"trackUserInteractions":true,
        "defaultPrivacyLevel":"mask-user-input","allowedTracingUrls":["https://bff.example.com"]}}
```
* No `rum` → RUM is not initialised. Only the public client token (`pub…`) is accepted; Datadog API/application
  keys are never used. `site` must be a Datadog site; rates 0–100; `sessionReplaySampleRate` is forced to 0.
* RUM init: `applicationId, clientToken, site, service, env, version, sessionSampleRate, sessionReplaySampleRate: 0,
  traceSampleRate, trackUserInteractions, trackResources: true, trackLongTasks: true, defaultPrivacyLevel,
  allowedTracingUrls` where each entry is `{match: <exact origin equality function>, propagatorTypes: ['tracecontext']}`.
  Entries must be origins (no path/wildcard; http only for localhost); default = origin of `apiBaseUrl`. Origin
  equality (not string prefix) prevents `https://api.example.com.evil.net` from matching.
* The app waits (≤ 1.5 s) for the RUM session before its first API call — found in e2e testing: requests issued
  before the RUM session exists are not traced.

## Hosting
* **Static Web Apps:** `public/staticwebapp.config.json` → navigation fallback to `index.html`, `config.json`
  no-store, immutable `/assets/*`, security headers and CSP (`connect-src` lists Azure app hosts + all Datadog
  browser-intake origins; the deployment root should narrow it to the real API origin + its site's intake), 404 →
  SPA. The deployment writes `config.json` next to the bundle (the zip artifact ships without it).
* **nginx container:** `Dockerfile` (node:24.21.0-alpine build → nginxinc/nginx-unprivileged:1.29.8-alpine, both
  digest-pinned, uid 101, port 8080). Env: `DD_SITE` (→ CSP intake origin, e.g. `us3.datadoghq.com` →
  `https://browser-intake-us3-datadoghq.com`), `API_ORIGIN` (CSP connect-src), `CONFIG_PATH` (mounted
  `/config/config.json`) or `APP_CONFIG_JSON`. Security headers, gzip, `config.json` no-store, `index.html`
  no-cache, `/assets/*` immutable 1 y, SPA fallback, `/healthz`, JSON access log.

## Build & test
```bash
npm ci && npm run typecheck && npm test      # vitest: 18 tests (config parsing, allowedTracingUrls, API client, polling, RUM init)
npm run build                                # dist/
npx playwright test                          # 2 e2e tests against `vite preview` with route-intercepted API + RUM intake
```
What the e2e proves: (1) the full journey renders (products → order → Pending/Reserved/Charged/Fulfilled
timeline) with no trace headers and no intake traffic when `rum` is absent; (2) with a RUM config (fake
applicationId/clientToken, intake `https://browser-intake-datadoghq.com` intercepted locally, nothing leaves the
machine) **every** request to the allowed API origin carries a W3C `traceparent` (`00-<32hex>-<16hex>-<flags>`),
none carries `x-datadog-*`, a request to another origin carries no `traceparent`, and the real RUM SDK posts a
batch to `/api/v2/rum` on page hide. It does not prove acceptance by Datadog's intake. Locally Playwright used the
pre-installed Chromium (`/opt/pw-browsers`, `PW_CHROMIUM_EXECUTABLE` override) because browser downloads are blocked.
Node: package.json requires `>=22`; vitest 5/vite 8 warn below Node 22.22.2 (sandbox has 22.22.0; tests pass).
