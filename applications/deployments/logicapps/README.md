# deploy-logicapps — Logic Apps Consumption + Standard

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Consumption**: `azurerm_logic_app_workflow` (identity `hello-logicapps`) + recurrence trigger (hourly) + actions from
  `workflows/consumption-batch-request.actions.json` (compose batch request → Service Bus queue `batch-items`; override with
  `settings.actions_file`) through a **managed Service Bus API connection authenticated with the managed identity**.
- **Standard**: `azurerm_logic_app_standard` on the platform WS1 plan (audit-archive workflow: order-events → Blob). The
  workflows (svc-logicapps zip with `connections.json`) are deployed by `scripts/deploy-zip.sh` (`az logicapp deployment
  source config-zip`). App settings: `serviceBus_fullyQualifiedNamespace`, `serviceBus_clientId`, `ARCHIVE_SUBSCRIPTION`
  (default `archive`), `AzureBlob_blobStorageEndpoint`, `ARCHIVE_CONTAINER`, OTel/DD env, `FUNCTIONS_WORKER_RUNTIME=dotnet`.
  Logs: WorkflowRuntime diagnostic settings (obs-diagnostics).

## Provider gap (azapi)
`Microsoft.Web/connections@2016-06-01`: `azurerm_api_connection` only exposes `parameter_values`; managed-identity
connections need `properties.parameterValueSet = {name: "managedIdentityAuth", values: {namespaceEndpoint: ...}}`
(Learn: "Authenticate workflow connections ... managed identities", ARM template section). schema validation is disabled
for this one resource because the embedded 2016-06-01 schema lacks `parameterValueSet`. Request: add this gap to
catalog/provider-gaps.yaml (owner deploy-logicapps).

## Storage for Standard
Logic Apps Standard (WS plans) needs the Azure Files content share ⇒ a storage connection: the access key is read
at plan time from the platform `logicapps_storage` account and set as `storage_account_access_key` (sensitive, **in
state** - documented exception). Microsoft Learn: key access cannot be disabled for Standard logic apps outside ASE v3,
and the runtime (not our code) reads `AzureWebJobsStorage`, so a `dsv://` reference cannot be used; Azure Key Vault
references are not used in this repository (ADR-0001 §14). Our own app settings carry `dsv://` references only.

- **Consumed contracts**: platform-appservice (`plans.logicapps`, `logicapps_storage`), platform-messaging,
  obs-telemetry-transport, foundation-identity, foundation-network (all registered in catalog/components.yaml).
- **Produced contract**: `deploy-logicapps`: `workflows.{consumption,standard}`, `apps`, `deploy_steps[logicapp-zip]`.

## Rollback / cost
Consumption definition is Terraform-managed (re-apply previous commit); Standard: redeploy previous zip.
Consumption ≈ $0.000025/action ⇒ < $1/month hourly; Standard WS1 ≈ $175/month (plan owned by platform-appservice).

## Requirements on other roots
platform-messaging: Data Sender on `batch-items` and a Data Receiver on subscription `archive` (new) for `hello-logicapps`.

## Test
`bash tools/validate/terraform.sh applications/deployments/logicapps` (fmt -check, init -backend=false, validate,
`terraform test` with mock providers: `tests/logicapps.tftest.hcl`).

Docs: https://learn.microsoft.com/azure/logic-apps/authenticate-with-managed-identity , https://learn.microsoft.com/azure/logic-apps/devops-deployment-single-tenant-azure-logic-apps
