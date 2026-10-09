# platform/compute/appservice — App Service plans

| | |
|---|---|
| Component id | `platform-appservice` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.appsvc-integration` delegated `Microsoft.Web/serverFarms`, `subnets.private-endpoints`, `private_dns_zones.{blob,queue,table,file}`), `foundation-identity` (declared; no grants today) |
| Produces | `platform-appservice` v1 |
| Status | `implemented` |

## What it creates

| Plan key | OS | Default SKU | Default | Workloads (architecture-matrix) |
|---|---|---|---|---|
| `linux` | Linux | P0v3 | on | hello-dbadapter-mysql (code), optional container apps, **Functions on Dedicated** (hello-functions cache-warmer) |
| `windows` | Windows | P0v3 | on | hello-inventory-api (.NET 10 code) |
| `windows_container` | WindowsContainer | P1v3 | **off** | inventory-api Windows container (cost) |
| `logicapps` | Windows (Workflow Standard) | WS1 (elastic ≤ 3) | **off** | Logic Apps Standard audit-archive workflow |

P0v3 is the smallest SKU with VNet integration + deployment slots; Pv4 SKUs (`P0v4`, `P1v4`, …) are accepted by
the provider and the settings validation if available in the region. Windows containers require P1v3+ (validated).

Logic Apps Standard also gets its **runtime storage account** (state, run history, content share). Azure Files
does not support identity-based access for the content share (`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`), so
shared keys stay enabled on this one account; the key never enters a contract — deploy-logicapps reads it at
deploy time through its own RBAC. Private by default (blob/queue/table/file private endpoints).

Not here: web/function/logic apps, app settings, slots (applications/deployments).

## Settings

`linux_plan{enabled,sku,worker_count,zone_balancing}`, `windows_plan{…}`, `windows_container_plan{…}`,
`logicapps_plan{enabled,sku,max_elastic_workers,storage_replication,storage_private}`.

## Cost at defaults (approx., USD/month)

P0v3 Linux ~60 + P0v3 Windows ~90 ≈ **150**. Windows container P1v3 ~+250; WS1 ~+175 + storage/PEs ~+30.

## Teardown / retention

Destroy requires the apps on the plans to be destroyed first. Logic Apps storage (run history) is deleted;
blob soft delete keeps deleted blobs 7 days while the account exists.

## Docs

- https://learn.microsoft.com/azure/app-service/overview-hosting-plans
- https://learn.microsoft.com/azure/app-service/overview-vnet-integration
- https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare
- https://learn.microsoft.com/azure/azure-functions/dedicated-plan
