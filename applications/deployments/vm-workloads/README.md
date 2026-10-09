# deploy-vm-workloads — workloads on VMs and VMSS Flexible

- **Owner**: applications layer. **Status**: implemented (mock tests; rendered scripts `bash -n` checked, PowerShell not executed).
- **Workloads**: `hello-worker` on the platform-vm Linux VM (`azurerm_virtual_machine_run_command`, rendered by module
  `vm-script`, which runs the **package's own `deploy/install.sh`** from applications/services/worker); `hello-inventory-api`
  as a **Windows service** on the platform-vm Windows VM (run command with `scripts/install-windows-service.ps1.tftpl`);
  `hello-worker` on the platform-vmss **Flexible** scale set (CustomScript extension on the model; existing instances via
  deploy step `vmss-flex-rollout` = `az vm run-command invoke` with output `vmss_rollout_script`).
  The VMSS **Uniform** workload (`hello-dbadapter-sqlvm`) lives in deploy-dbadapters.
- **Package delivery (no SAS in state)**: scripts get an IMDS token for `https://storage.azure.com/` with the host's
  user-assigned identity and download the immutable package URL, verify sha256, install a new release directory,
  switch atomically, health-check (`/healthz`) and roll back automatically on failure. Secrets (inventory `FAULT_TOKEN`)
  are fetched from Key Vault on the host with an IMDS token for `https://vault.azure.net` — never in Terraform state.
- **Consumed contracts**: platform-messaging, obs-telemetry-transport, foundation-identity; optional platform-vm, platform-vmss,
  platform-db-table-storage (worker `TABLE_MODE=table`), platform-db-cosmos-nosql (**not in components.yaml**; inventory Cosmos).
- **Produced contract**: `deploy-vm-workloads`: `apps.{worker-vm,inventory-vm,worker-vmss}`, `deploy_steps`.

## Settings / env
`linux_worker`, `windows_inventory`, `vmss_worker`, `package_force` (bump to re-run), `worker_concurrency`, `faults_enabled`.
Env: OTLP to the local Datadog Agent (`http://localhost:4317`, gRPC — agent installed by obs-hosts), `LOG_FILE_PATH`
(`/var/log/hello-worker/worker.log` — the worker unit only allows writes there; Windows `<log_dir>\inventory-api.log`),
`AZURE_CLIENT_ID`, `AZURE_CREDENTIAL_MODE=managed_identity`, worker `SB_TOPIC/SB_SUBSCRIPTION/TABLES_ENDPOINT/TABLE_NAME`,
inventory `STORAGE_MODE/COSMOS_*` (service-scoped registry environment).

## Rollback
Re-apply with the previous package (run command / extension re-runs); installers keep 3 releases; worker also supports
`install.sh --rollback`. VMSS Flexible: re-run `deploy-zip.sh` (`vmss-flex-rollout`).

## Requirements on other roots
Identities `hello-worker` / `hello-inventory-api` need Storage Blob Data Reader on the packages container; the inventory
identity reads `fault-token` (granted by foundation-identity).

Docs: https://learn.microsoft.com/azure/virtual-machines/run-command-managed , https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
