# web-app — one App Service web app (azurerm)

Owner: applications layer. Used by `appservice` and `dbadapters`.

**Purpose**: a Linux or Windows web app (code zip or digest-pinned container) with the workload's user-assigned identity
(ACR pull; the app reads Delinea DSV with it), regional VNet integration, health check, either a private endpoint or
deny-by-default access restrictions, and a `staging` slot (when the plan SKU supports slots) for swap-based releases.
App settings carry plain values and `dsv://` references; inline passwords/keys and `@Microsoft.KeyVault(` references are
rejected by variable validation. Logs go through diagnostic settings owned by observability (no sidecar).

**Inputs / outputs**: see `variables.tf` / `outputs.tf` (every variable and output is described).

**Tests**: through the consuming roots, e.g. `bash tools/validate/terraform.sh applications/deployments/appservice`.
