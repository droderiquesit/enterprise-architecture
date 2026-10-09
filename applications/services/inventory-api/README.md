# hello-inventory-api (.NET 10)

Owner: applications / .NET builder. Component: `svc-inventory-api` (artifacts: zip packages win-x64 + linux-x64, container image).

Stock levels and reservations for Enterprise Hello. Runs on Linux and Windows: App Service Windows (code, ANCM
in-process via the generated `web.config`), Windows VM as a Windows Service (`AddWindowsService`, Kestrel, no IIS),
Linux containers (ACA/AKS) and a Nano Server container.

## Data boundary

Owns Azure Cosmos DB for NoSQL database `inventory`, container `items`, partition key `/sku` (created by the platform
root; the app never creates databases/containers). Documents (snake_case):

- item: `{id: <sku>, sku, doc_type: "item", quantity (available), reserved, updated_at}`
- reservation: `{id: "reservation:<order_id>", sku, doc_type: "reservation", order_id, quantity, status: reserved|released, created_at, updated_at}`

Reserve and release are one **transactional batch** in the SKU partition (create/replace reservation + replace item with
`If-Match` ETag), retried up to 5 times on 409/412. Reservation is idempotent by `order_id`.
Required data-plane role for the workload identity: *Cosmos DB Built-in Data Contributor* (granted by the platform root).

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/inventory/{sku}` | `{sku, quantity, reserved, updated_at}`; 404 problem `unknown-sku` |
| PUT | `/inventory/{sku}` | `{quantity: 0..1000000}` — sets available quantity (keeps reserved) |
| POST | `/inventory/{sku}/reserve` | `{order_id, quantity}` → 200 `{reservation_id, order_id, sku, quantity, status, replayed, available}`; 409 problem `insufficient-stock` (with `available`); 404 unknown SKU |
| POST | `/inventory/{sku}/release` | `{order_id}` — compensation used by hello-durable; idempotent (`replayed: true` on repeat, `status: not_found` when there was no reservation). *Addition to the shared interface spec.* |
| POST | `/inventory/seed` | deterministic: SKU-0001..SKU-0020, quantity 100 + 10·n, reserved 0 |
| GET | `/healthz`, `/readyz`, `/version` | readiness reads the container (2 s) |
| POST/GET/DELETE | `/admin/faults` | lab fault injection (`db_error` → 503 on store calls) |

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | 8080 | ignored under IIS/ANCM (App Service Windows) |
| `STORAGE_MODE` | `cosmos` | `cosmos` \| `memory` |
| `COSMOS_ENDPOINT` | — | `https://<account>.documents.azure.com:443/` (managed identity via `AZURE_CLIENT_ID`) |
| `COSMOS_DATABASE`, `COSMOS_CONTAINER` | `inventory`, `items` | |
| `COSMOS_CONNECTION_MODE` | `direct` | `gateway` when only HTTPS/443 is open (e.g. restrictive NSGs, App Service with private endpoint) |
| `COSMOS_CONNECTION_STRING` | — | emulator/local only |
| common | | `DD_*`, `GIT_COMMIT`, `BUILD_TIME`, `OTEL_*`, `LOG_LEVEL`, `LOG_FILE_PATH`, `FAULTS_ENABLED`, `FAULT_TOKEN`, `AZURE_CLIENT_ID` |

Cosmos client: 5 s request timeout, max 3 throttling retries / 5 s wait, distributed tracing on.

## Telemetry

- Spans: ASP.NET Core server; Cosmos SDK operation spans (`Azure.Cosmos.Operation` ActivitySource, enabled through the
  `Azure.Experimental.EnableActivitySource` switch set by Hello.Common).
- Metrics: `hello.inventory.reservations{result=reserved|replayed|insufficient|unknownsku|released|alreadyreleased|notfound}`,
  `hello.faults.injected`, ASP.NET Core/runtime.
- Logs: JSON with `order_id`, `sku`, `quantity`, `reservation_outcome`. On App Service Windows stdout is captured as
  `AppServiceConsoleLogs` (diagnostic settings → Event Hubs → Fluent Bit). On a Windows VM set `LOG_FILE_PATH`
  (e.g. `C:\ProgramData\hello\logs\inventory.log`) for the Fluent Bit service to tail.

## Packages and hosting

```bash
applications/dotnet/build.sh publish inventory-api
# → .artifacts/inventory-api/hello-inventory-api-<ver>-win-x64.zip   (self-contained, web.config + Hello.InventoryApi.exe)
# → .artifacts/inventory-api/hello-inventory-api-<ver>-linux-x64.zip (framework-dependent, needs ASP.NET Core 10 runtime)
```

Windows VM service install (performed by the deployment root's run-command, shown for reference):
`sc.exe create hello-inventory-api binPath= "C:\hello\inventory\Hello.InventoryApi.exe" start= delayed-auto` with
machine-level env vars (`PORT`, `STORAGE_MODE`, `COSMOS_ENDPOINT`, `AZURE_CLIENT_ID`, `DD_*`, `LOG_FILE_PATH`).

Containers: `Dockerfile` (Linux, chiseled-extra, uid 1654) — built and run locally;
`Dockerfile.windows` (Nano Server ltsc2025, `ContainerUser`) — **not built here** (needs a Windows Server 2025 Docker host).

## Run locally / test

```bash
cd applications/dotnet
STORAGE_MODE=memory dotnet run --project ../services/inventory-api/src/Hello.InventoryApi
dotnet test --project ../services/inventory-api/tests/Hello.InventoryApi.Tests
```

Tests cover seed determinism, idempotent reserve/release, 409 insufficient stock problem, validation, `db_error` fault.
The Cosmos implementation is compiled and type-checked but not exercised against Cosmos/emulator in this sandbox.
