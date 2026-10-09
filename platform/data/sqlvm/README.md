# SQL Server on Azure VM (platform-db-sqlvm)

- **Component id:** `platform-db-sqlvm` (catalog/components.yaml; catalog refs: `sql-server-on-vm`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `implemented` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Windows Server 2022 VM from the Marketplace image **MicrosoftSQLServer : sql2022-ws2022 : sqldev-gen2 : latest**
(SQL Server 2022 Developer — free license for dev/test, PAYG license type), registered with the SQL IaaS Agent
extension (`azurerm_mssql_virtual_machine`; management modes were removed in March 2023), private connectivity only,
separate data (F:) and log (G:) disks, daily auto-shutdown, and database `adapter` + least-privileged SQL login
`dbadapter` created by `scripts/init-adapter-db.ps1` (VM run command).

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-sqlvm` v1 — schema `catalog/contracts/platform-db-sqlvm.v1.schema.json` (output `contract`, no secrets).
VM (id, private IP, principal ID), server (port, auth `sql-login`, admin password secret ID), database `adapter` (login `dbadapter`, `password_secret_id`), and `dbm` (`deployment_type = self_hosted_azure_vm`: the Agent runs on the VM and connects to localhost with SQL login `datadog`; password secret `dbm-sqlvm-password` from `foundation_identity.secret_ids`, convention fallback).

## Settings (`components.platform-db-sqlvm` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `vm_size` | `Standard_B2ms` |
| `image.{publisher,offer,sku,version}` | `MicrosoftSQLServer`, `sql2022-ws2022`, `sqldev-gen2`, `latest` |
| `os_disk_type`, `data_disk_type`, `data_disk_gb`, `log_disk_gb` | StandardSSD_LRS, StandardSSD_LRS, 32, 32 |
| `auto_shutdown.{enabled,time,timezone}` | `true`, `1900`, `UTC` |
| `admin_secret_name`, `dbadapter_secret_name`, `dbm_secret_name`, `secret_version` | `sqlvm-admin-password`, `sqlvm-dbadapter-password`, `dbm-sqlvm-password`, 1 |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
~USD 40-90: B2ms Windows ~USD 0.1/h (≈75 always-on; less with auto-shutdown — the VM is not auto-started), 3 StandardSSD disks ~10. SQL Developer edition has no license charge.

## Private networking
NIC in subnet `compute`, no public IP; `sql_connectivity_type = PRIVATE` (port 1433 inside the VNet). Data disks deny public network access.

## Authentication and data-plane access
**SQL authentication** is used for hello-dbadapter-sqlvm. Microsoft Entra authentication for SQL Server 2022 on Azure
VMs is supported through the SQL IaaS Agent extension, but azurerm 5.9 does not expose it
(`azurerm_mssql_virtual_machine` has no Entra settings) and it additionally needs Graph permissions for the VM
identity; it is left as a documented follow-up (AzAPI `Microsoft.SqlVirtualMachine/sqlVirtualMachines`) rather than
implemented. Passwords are generated with `random_password` (stored in encrypted, RBAC-restricted state because the
VM/SQL VM arguments have no write-only variant) and written **write-only** to Key Vault; the contract carries only
versionless secret IDs. The apply identity needs *Key Vault Secrets Officer* on the foundation vault.

## Teardown and data retention
Destroy removes VM, disks and the SQL VM registration; the Key Vault secrets are deleted (soft-delete/purge protection of the vault applies).
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- Entra auth not implemented (see above). Encryption at host requires the `EncryptionAtHost` subscription feature (checkov skip annotated).
- Auto-shutdown does not auto-start; the deploy-vm-workloads pipeline or an operator must start the VM.
- VM extensions (Datadog Agent, Fluent Bit) are observability-owned.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py sqlvm                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/create-sql-vm-powershell
- https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-iaas-agent-extension-automate-management
- https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm
- https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
