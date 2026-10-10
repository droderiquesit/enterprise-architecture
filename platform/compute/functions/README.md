# platform/compute/functions — Functions hosting plans + runtime storage

| | |
|---|---|
| Component id | `platform-functions` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.private-endpoints`, `subnets.flex-integration`, `subnets.appsvc-integration`, `private_dns_zones.{blob,queue,table}`, `egress.public_ips`), `foundation-identity` (`hello-durable`, `hello-functions`) |
| Produces | `platform-functions` v1 (account names/endpoints/containers; no keys) |
| Status | `implemented`; Durable Task Scheduler via **azapi** (provider gap) |

## What it creates

| Capability | Default | Resources |
|---|---|---|
| **Flex Consumption** (one app per plan) | on: `durable` → hello-durable | `azurerm_service_plan` `FC1` (Linux) + host/deployment storage (container `deploy-durable`) |
| **Durable runtime storage** | on | separate account for the task hub (blob/queue/table Data Contributor for hello-durable) — Durable runtime state ≠ business DB (SQL `fulfillment`) ≠ host storage |
| Elastic Premium (Linux) | off | `EP1` (elastic ≤ 3) + host storage with `packages` container — hello-functions audit trigger |
| Windows Consumption | off | `Y1` + **public** Entra-only storage with `packages` container — .NET isolated Reconciliation |
| Durable Task Scheduler | off | `Microsoft.DurableTask/schedulers@2026-02-01` + task hub (azapi), *Durable Task Data Contributor* for hello-durable |

The app root wires it up with `azurerm_function_app_flex_consumption`:
`service_plan_id = flex.durable.plan_id`, `storage_container_type = "blobContainer"`,
`storage_container_endpoint = flex.durable.deployment_container_url`,
`storage_authentication_type = "UserAssignedIdentity"`, `storage_user_assigned_identity_id = <hello-durable id>`,
`virtual_network_subnet_id = flex_integration_subnet_id`; host storage via `AzureWebJobsStorage__accountName`
+ `__credential=managedidentity` + `__clientId`.

### Storage security

All runtime accounts come from `platform/modules/compute-runtime-storage`: **`shared_access_key_enabled =
false`**, OAuth default, TLS 1.2, no public blobs, public network access **disabled** with blob/queue/table
private endpoints (`private_endpoints_enabled = true`). Host-identity grants: Blob Data **Owner**, Queue/Table
Data Contributor (Functions host requirements).

- Premium and Windows Consumption apps must run **without Azure Files** (`WEBSITE_RUN_FROM_PACKAGE` blob URL +
  managed identity, `WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID`): Azure Files has no identity-based access,
  and keeping shared keys off is the point. Scale-out can be slower without Azure Files (Learn).
- Windows Consumption has **no VNet integration**, so its storage stays publicly reachable (Entra ID only).
- Linux Consumption retires **2028-09-30** and is intentionally not offered.

## Durable Task Scheduler (azapi gap)

`azurerm` 5.9 has no `Microsoft.DurableTask` resources → `azapi_resource` with API `2026-02-01` (GA; present
in azapi 2.13 schemas). `ipAllowlist` defaults to the lab egress IPs (`allow_egress_ips`) — the scheduler
still requires Entra ID. Empty list falls back to `0.0.0.0/0`.

## Settings

`private_endpoints_enabled`, `storage_replication`, `flex_apps{key → identity, storage_suffix}`,
`durable_storage{}`, `premium_plan{enabled,sku,max_elastic_workers,identity,storage_suffix}`,
`consumption_windows_plan{}`, `durable_task_scheduler{enabled,sku,capacity,task_hub,identity,ip_allowlist,allow_egress_ips}`.

## Cost at defaults (approx., USD/month)

Flex Consumption: pay per execution/GB-s (≈0 idle, no always-ready) + 2 storage accounts (~2) + 6 private
endpoints (~44). EP1 ≈ +150. Y1 ≈ 0 idle. DTS Consumption: per-action billing.

## Teardown / retention

Destroy deletes deployment packages and Durable task hub state (orchestration history) — synthetic data.
Blob soft delete keeps deleted blobs 7 days while the account exists.

## Known limitations / prerequisites

- Deployment (zip upload to the private container) needs VNet-connected agents or `private_endpoints_enabled = false`.
- The `flex-integration` subnet must be delegated to `Microsoft.App/environments` (foundation).

## Validation

```bash
tools/validate/terraform.sh platform/compute/functions   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## Docs

- https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
- https://learn.microsoft.com/azure/azure-functions/storage-considerations
- https://learn.microsoft.com/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity
- https://learn.microsoft.com/azure/azure-functions/durable/durable-task-scheduler/durable-task-scheduler
- https://learn.microsoft.com/azure/templates/microsoft.durabletask/schedulers
