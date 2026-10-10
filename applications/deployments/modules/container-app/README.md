# container-app — one Azure Container App (azurerm)

Owner: applications layer. Used by `core-aca` and `dbadapters`.

**Purpose**: one `azurerm_container_app` with the workload's user-assigned identity (ACR pull; the app and dsv-fetch
read Delinea DSV with it), a digest-pinned image, the `app-env` environment (secret settings are `dsv://` references),
`/healthz` startup/liveness and `/readyz` readiness probes, an HTTP concurrency scale rule and Multiple-revision traffic
weights for canary / rollback. The observability patch (`app-env` output `container_app_patch`) adds the Datadog
serverless-init sidecar and the identity-free `dsv-fetch-install` init container by default; with
`log_pipeline = fluent_bit_direct` a Fluent Bit sidecar whose key a dsv-fetch init container (Consumption profile) or
refresher container (Dedicated profiles) writes. Container Apps secrets hold only non-secret sidecar config files.

**Inputs / outputs**: see `variables.tf` / `outputs.tf` (every variable and output is described). The revision suffix
is derived from the template hash, so every template change creates an addressable revision (`revision_suffix` output).

**Tests**: through the consuming roots, e.g. `bash tools/validate/terraform.sh applications/deployments/core-aca`.
