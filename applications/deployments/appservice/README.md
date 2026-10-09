# deploy-appservice — App Service workloads

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Apps** (module `web-app`): `hello-inventory-api` Windows **code** (self-contained win-x64 zip, `WEBSITE_RUN_FROM_PACKAGE=1`,
  .NET `v10.0` stack) on the platform `windows` plan; optional Windows **container** variant on `windows_container`
  (`settings.inventory.container_enabled`, disabled by default — Premium v3 Windows container cost); optional
  `hello-catalog-api` Linux **container** (`catalog_container_enabled`, needs platform-db-postgresql).
- **Slots**: `staging` slot when the SKU supports slots (Standard/Premium/Isolated — P0v3 is Premium v3 and supports
  slots); deploy goes to staging, then swap.
- **Consumed contracts**: platform-appservice, platform-shared, obs-telemetry-transport, foundation-identity; optional
  platform-db-cosmos-nosql (inventory db; absent ⇒ `STORAGE_MODE=memory`), platform-db-postgresql, platform-db-redis,
  foundation-network (private endpoints; **not in components.yaml**).
- **Produced contract**: `deploy-appservice`: `apps.hello-inventory-api.{id,url,staging_slot,...}`, `endpoints`, `deploy_steps[webapp-zip]`.

## App settings
Common OTel/DD env (gateway), `AZURE_CLIENT_ID`, `FAULTS_ENABLED`, `FAULT_TOKEN` = `@Microsoft.KeyVault(SecretUri=...)`
(resolved with `key_vault_reference_identity_id` = the app identity), inventory `STORAGE_MODE`, `COSMOS_ENDPOINT/DATABASE/
CONTAINER`, `COSMOS_CONNECTION_MODE=gateway`; catalog container `PG_*`, `REDIS_*`, `WEBSITES_PORT=8080`. No sidecars:
logs via diagnostic settings (AppServiceConsoleLogs → Event Hubs, obs-diagnostics).

## Deploy / rollback
`scripts/deploy-zip.sh`: `az webapp deploy --type zip --slot staging` → probe `/healthz` → `az webapp deployment slot
swap --slot staging`. Rollback = swap again (the previous build is in staging). Containers: previous digest.

## Network
`network_mode=auto`: private endpoint (`sites`) when foundation-network is provided; otherwise public with
`ip_restriction_default_action = Deny` + `allowed_ip_ranges`. VNet integration on `appsvc-integration`, route-all.

## Cost
No plan cost here (plans owned by platform-appservice: P0v3 ≈ $60–80/month each). Staging slot: no extra charge.

## Limitations
`PORT` is not set for the Windows code app (ANCM supplies the port); hello-inventory-api must not force `PORT` there.

Docs: https://learn.microsoft.com/azure/app-service/deploy-staging-slots , https://learn.microsoft.com/azure/app-service/deploy-zip ,
https://learn.microsoft.com/azure/app-service/app-service-key-vault-references
