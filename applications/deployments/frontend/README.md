# deploy-frontend — hello-frontend on Azure Static Web Apps

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Purpose**: `azurerm_static_web_app` (location `settings.swa_location`, default **westeurope** — SWA is not offered in
  swedencentral, ADR amendment) and the **rendered runtime configuration**. Content upload is a pipeline step.
- **Consumed contracts**: obs-prereqs (RUM application `hello-frontend`), foundation-identity; optional deploy-core-aca /
  deploy-core-aks (`public_api.origin`), foundation-edge (Front Door hostname).
- **Produced contract**: `deploy-frontend`: `url`, `static_web_app.{id,name,default_hostname}`, `runtime_files` (config.json,
  staticwebapp.config.json, version.json, healthz.json as JSON strings), `deploy_steps[swa]`, `api_origin`.

## Runtime config (owned here)
`config.json`: `{env, service, version, apiBaseUrl (API origin; the SPA calls <apiBaseUrl>/api/...), rum{applicationId,
clientToken, site, service, env, version, sessionSampleRate, sessionReplaySampleRate: 0, trackUserInteractions,
defaultPrivacyLevel: mask-user-input, allowedTracingUrls: [first-party API origins]}}`. The RUM client token is a
browser-facing credential by design (obs-prereqs README). `staticwebapp.config.json`: SPA fallback, `no-store` on
config.json, rewrites `/healthz` `/readyz` `/version` to static JSON (smoke contract), and CSP whose `connect-src`
allows `'self'`, the API origin(s) and the Datadog browser intake for the site (`browser-intake-<site>`).

## Deploy / rollback
`scripts/deploy-swa.sh --contract <contract>`: package from svc-frontend (Entra download + sha256), runtime files
written into the bundle, deployment token fetched at deploy time with `az staticwebapp secrets list` (never output or
stored), SWA CLI upload. Rollback: re-run with the previous svc-frontend package.

## Settings
`swa_location` (westeurope), `sku` (Free | Standard — Standard for private endpoint/custom auth), `api_origin` override,
`prefer_api` (aca|aks), `rum_app_key`, `extra_tracing`.

## Cost
Free SKU $0 (Standard ≈ $9/month/app).

## Networking / limitations
Free SKU is public (static files only; APIs remain behind their own controls). Private endpoint needs Standard and a
platform-owned private endpoint (not created here). If no API contract is present the check `api_origin_known` warns
and config.json points to `https://api.invalid`.

## Test
`bash tools/validate/terraform.sh applications/deployments/frontend` (fmt -check, init -backend=false, validate,
`terraform test` with mock providers: `tests/frontend.tftest.hcl`).

Docs: https://learn.microsoft.com/azure/static-web-apps/configuration , https://docs.datadoghq.com/real_user_monitoring/browser/setup/ ,
https://docs.datadoghq.com/real_user_monitoring/correlate_with_other_telemetry/apm/
