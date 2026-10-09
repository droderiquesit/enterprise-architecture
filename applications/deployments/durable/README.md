# deploy-durable — hello-durable on Functions Flex Consumption

- **Owner**: applications layer. **Status**: implemented (mock tests); Flex deployment not verified.
- **Resources**: `azurerm_function_app_flex_consumption` (runtime `dotnet-isolated` `10.0` — Flex supports .NET 8/9/10
  isolated per Learn "Flex Consumption plan hosting"), on the platform-functions FC1 plan, in the platform-functions
  resource group (webspace constraint). Optional `azurerm_windows_function_app` on the Windows Consumption (Y1) plan running
  **only Reconciliation** (created when platform-functions publishes `consumption_windows`). Private endpoint (`sites`)
  when foundation-network is provided.
- **Consumed contracts** (catalog/components.yaml): platform-functions (`flex.durable`, `consumption_windows`),
  platform-messaging, platform-db-sql (`fulfillment`), obs-telemetry-transport, foundation-identity, foundation-network
  (private endpoint, VNet integration); optional deploy-partner-sim (`url` → `PARTNER_API_URL`), deploy-core-aca /
  deploy-core-aks (`apps["hello-orders-api"].url` → `ORDERS_API_URL`; Kubernetes-internal `*.svc.cluster.local` URLs
  are ignored because Functions cannot resolve them), deploy-appservice (`hello-inventory-api` app url →
  `INVENTORY_API_URL`, falling back to the core contracts). `settings.{orders,inventory,partner}_api_url` override the
  derived values.
- **Produced contract**: `deploy-durable`: `function_app.{id,name,hostname,private}`, `reconciliation_app`, `task_hub`,
  `apps`, `deploy_steps[functionapp-flex]`.

## App settings (owned here)
`AzureWebJobsStorage__accountName/__credential=managedidentity/__clientId` (identity-based host + Durable storage),
deployment storage = Flex `blobContainer` with the user-assigned identity (no keys), `DURABLE_TASK_HUB`
(`hellodurable<env>`), `RECONCILE_SCHEDULE`, `ServiceBusConnection__fullyQualifiedNamespace/__credential/__clientId`,
`SERVICEBUS_FQDN`, `BATCH_ITEMS_QUEUE`, `SQL_CONNECTION_STRING` (no password) + `SQL_USE_AZURE_CREDENTIAL=true`,
`STORAGE_MODE=sql`, `ORDERS_API_URL`/`INVENTORY_API_URL`/`PARTNER_API_URL` (settings override > upstream contracts > unset ⇒ simulated), `PAYMENT_TIMEOUT_SECONDS`,
`DURABLE_HISTORY_RETENTION_DAYS`, `FAULTS_ENABLED`, `FAULT_TOKEN` (`dsv://` reference resolved by the app), `DSV_*`,
`FAULT_ACTIVITY_FAILURE_RATE` (only when faults_enabled), `OTEL_*` (gateway, `http/protobuf`, generic endpoint so the
host emits Durable V2 spans), `AzureFunctionsJobHost__telemetryMode=OpenTelemetry`. Flex forbids
`WEBSITE_RUN_FROM_PACKAGE` / `FUNCTIONS_WORKER_RUNTIME` (not set). Function placement: Flex disables
`ReconciliationTimer`/`StartReconciliation` when the Y1 app exists; Y1 disables `OrderEventsStarter`,
`StartOrderWorkflow`, `StartBatch`, `PurgeHistory` and uses task hub `<hub>rec`.

## Network
Durable HTTP functions are anonymous at the Functions layer, so the app is private: `network_mode=auto` ⇒ private
endpoint when foundation-network is supplied, otherwise public endpoint with `ip_restriction_default_action=Deny`
plus `allowed_ip_ranges` (deploy agent egress IPs). VNet integration: `flex-integration` subnet. The Y1 app cannot use
private endpoints/VNet integration — deny-by-default restrictions only.

## Deploy / rollback
`scripts/deploy-zip.sh`: `az functionapp deployment config show` (deployment storage check) +
`az functionapp deployment source config-zip` (one deploy, Learn "Package-based deployment"). No slots on Flex:
rollback = redeploy the previous package. Y1 runs from the package URL (`WEBSITE_RUN_FROM_PACKAGE` +
`WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID`), so its rollback is re-apply with the previous artifact.

## Smoke
`/api/healthz`, `/api/readyz` (Durable client round-trip), `/api/version`. The contract publishes
`endpoints["hello-durable"] = https://<host>/api`, so `tools/smoke/smoke.py` probes all three (from a network that can
reach the private endpoint); `scripts/smoke.sh` remains for ad-hoc checks.

## Cost
Flex on-demand, scale to zero: ≈ $0 idle; ~$0.000026/GB-s + executions; 2 GB instances. Y1: free grant covers lab use.

## Limitations
Y1 identity-based storage without Azure Files and run-from-package-with-MI are documented features but unverified here.
Durable state uses `AzureWebJobsStorage` (host.json `connectionName`); the separate platform `durable_storage` account
is unused until host.json points at another connection.

Docs: https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan , https://learn.microsoft.com/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity ,
https://learn.microsoft.com/azure/azure-functions/deployment-zip-push
