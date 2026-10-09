# deploy-functions — hello-functions on three Functions hosting options

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Hosts** (catalog/architecture-matrix.yaml): `premium` — Elastic Premium EP1 Linux (platform-functions `premium`),
  Python 3.13, function `audit` (Service Bus topic `order-events` / subscription `audit` → Confidential Ledger or Table
  Storage); `dedicated` — the platform-appservice Linux plan, `cache_warmer` (timer, always on); `aca` — **Functions on
  Container Apps V2** (`Microsoft.App/containerApps` `kind=functionapp`, **azapi**) running `quote` (HTTP) from the
  svc-functions image. Each host sets `AzureWebJobs.<name>.Disabled=true` for the functions it does not own
  (`settings.function_names`, default `audit`, `cache_warmer`, `quote`).
- **Consumed contracts** (all registered in catalog/components.yaml): platform-functions, platform-messaging,
  obs-telemetry-transport, foundation-identity, platform-shared (ACR for the ACA host), foundation-network; optional
  platform-appservice, platform-containerapps, platform-db-ledger, platform-db-table-storage
  (`AUDIT_SINK` = `ledger` when the ledger contract is supplied, else `table` with the table-storage contract, else `log`).
- **Produced contract**: `deploy-functions`: `function_apps.{premium,dedicated,aca}.{id,name,hostname,functions}`, `apps`.

## Provider gap (azapi)
`Microsoft.App/containerApps@2026-01-01` with `kind = "functionapp"`: azurerm_container_app exposes `kind` as computed.
catalog/provider-gaps.yaml (`functions-on-container-apps`) records the same `2026-01-01` version — the newest one embedded in
azapi 2.13.0's schema, so the root keeps schema validation on.

## App settings
Identity storage (`storage_uses_managed_identity` + `AzureWebJobsStorage__credential/__clientId`, host storage = the
premium runtime account), `content_share_force_disabled` + `WEBSITE_RUN_FROM_PACKAGE=<package URL>` with
`WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID` (no Azure Files, no SAS), `ServiceBusConnection__*` (identity),
`AUDIT_SINK` (`ledger`|`table`|`log`, read by `hello_functions.handlers.audit_sink_from_env`), `LEDGER_ENDPOINT/LEDGER_COLLECTION=order-audit` or `TABLES_ENDPOINT/AUDIT_TABLE`, `CACHE_WARM_SCHEDULE`,
`CATALOG_API_URL`, `FUNCTIONS_HOST`, OTel (HTTP to gateway), `FAULT_TOKEN` as `dsv://` reference (resolved by the app). ACA host: same
env, Fluent Bit sidecar with a dsv-fetch init container (ACA log route); ACA secrets hold only the sidecar config files.

## Rollback
Premium/Dedicated run from the package URL: re-apply with the previous svc-functions artifact. ACA: previous digest.

## Cost
EP1 (always ≥1 instance) ≈ $150/month (dominant; disable with `premium_enabled=false`), Dedicated shares the P0v3
plan, ACA scale-to-zero ≈ $0 idle.

## Limitations
Python packages for run-from-package must include `.python_packages` (built by the Python builder). Network:
private endpoints when foundation-network is supplied, else deny-by-default restrictions.

Docs: https://learn.microsoft.com/azure/container-apps/functions-overview , https://learn.microsoft.com/azure/azure-functions/run-functions-from-deployment-package ,
https://learn.microsoft.com/azure/azure-functions/disable-function
