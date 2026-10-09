# hello-logicapps

Workflow artifacts (no application code). **Data boundary:** blob container `order-archive` (Standard) and Service
Bus queue `batch-items` messages (Consumption).

## Standard — `standard/` → `hello-logicapps-standard-<ver>.zip` (zip deploy to the Logic App Standard site)
* `audit-archive/workflow.json` (Stateful): built-in **Service Bus** trigger `receiveTopicMessages` on topic
  `order-events`, subscription **`archive`** (the `audit` subscription is consumed by hello-functions), `splitOn`
  per message → Compose → built-in **Azure Blob** `uploadBlob` to `@parameters('archiveContainer')` at
  `yyyy/MM/dd/<messageId>.json` (overwrite = idempotent on redelivery), exponential retry.
* `connections.json`: `serviceProviderConnections` for `serviceBus` and `AzureBlob`, `parameterSetName`
  `ManagedServiceIdentity` (no connection strings / keys).
* `parameters.json`, `host.json` (bundle `Microsoft.Azure.Functions.ExtensionBundle.Workflows` `[1.*, 2.0.0)`).
* App settings the deployment root must set: `serviceBus_fullyQualifiedNamespace`, `AzureBlob_blobStorageEndpoint`,
  `ARCHIVE_CONTAINER`. Microsoft Learn notes most built-in service-provider connectors authenticate with the
  **system-assigned** identity: grant it *Azure Service Bus Data Receiver* on `order-events/archive` and *Storage Blob
  Data Contributor* on the archive container.
* **Required elsewhere:** platform-messaging must create subscription `archive` on topic `order-events`.

## Consumption — `consumption/batch-request.definition.json`
Workflow definition loaded by the deployment root: hourly Recurrence → `For_each` (concurrency 5) over
`range(0, batchSize)` → managed **Service Bus** connector (`ApiConnection`) sends `{item_id, batch_id, source}` to
queue `batch-items` with `MessageId` = `<batchId>-<n>` (duplicate-detection friendly). Parameters `$connections`,
`queueName` (batch-items), `batchSize` (10). `consumption/connections.example.json` shows the `$connections` value
for a managed API connection with **managed identity** (`ManagedServiceIdentity`, user-assigned).

## Tests
`pytest` (11): JSON well-formedness of every file; Consumption definition validates against the **official**
Workflow Definition Language schema (2016-06-01, vendored in `tests/schemas/`, fetched 2026-10-09); Standard
workflow validates against the same schema extended only with the Standard-only `ServiceProvider` operation type,
plus cross-checks (connection names, app settings, parameters, runAfter). Not deployed/validated by the Logic Apps
service itself.
