# platform/compute/specialized — specialized compute (all off)

| | |
|---|---|
| Component id | `platform-specialized-compute` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.compute`), `foundation-identity` (`hello-worker`, `hello-jobs`) |
| Produces | `platform-specialized-compute` v1 (per-capability status) |
| Status | every capability **`disabled`** by default; AVS **`blocked`** (cataloged only) |

| Capability | Setting | What is created when enabled | Notes |
|---|---|---|---|
| Confidential VM | `confidential_vm.enabled` | Ubuntu 24.04 **`cvm`** image on `Standard_DC2as_v5` (AMD SEV-SNP), `security_encryption_type = VMGuestStateOnly`, Secure Boot + vTPM, hello-worker | DCasv5 is current (DCas_cc_v5 retired 2026-09-01); verify image `az vm image list -p Canonical -f ubuntu-24_04-lts -s cvm`; needs DCASv5 quota |
| Dedicated host | `dedicated_host.enabled` | host group (1 FD) + host `DSv5-Type1` + one D2s_v5 VM on it | a whole host is billed (~USD 2,000+/month) |
| GPU VM | `gpu_vm.enabled` | `Standard_NC4as_T4_v3` Ubuntu 24.04 | needs *Standard NCASv3_T4 Family* quota; NVIDIA driver install belongs to the deployment |
| Automation | `automation.enabled` | Automation account (Basic, local auth off, public network access off, system + hello-jobs identity) + placeholder hourly schedule `hello-health-probe` | the python3 runbook + job schedule are owned by `applications/deployments/specialized` |
| Machine Learning | `ml.enabled` | AML workspace (managed network, AllowInternetOutbound) + CPU compute cluster 0→1 (`LowPriority`, no public IP) | the workspace **requires** Application Insights, Key Vault and a storage account (azurerm marks them required) → created here as **platform-required dependencies** (workspace-based App Insights on its own 0.5 GB/day workspace, RBAC Key Vault, identity-only storage `storage_account_access_type = "Identity"`) — not observability resources |
| Azure VMware Solution | — | nothing (cataloged, **blocked**) | AVS needs a private cloud of ≥ 3 dedicated bare-metal hosts (quota request via support, ExpressRoute/Global Reach connectivity, /22 management block); far outside lab scope/cost |

All VMs: no public IPs, cloud-init OS baseline, auto-shutdown 19:00 UTC, Entra-only identities; break-glass
password in state only unless `admin_ssh_public_key` is set.

## Cost at defaults

0 (nothing enabled).

## Docs

- https://learn.microsoft.com/azure/confidential-computing/confidential-vm-overview
- https://learn.microsoft.com/azure/virtual-machines/dedicated-hosts
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/ncast4v3-series
- https://learn.microsoft.com/azure/automation/overview
- https://learn.microsoft.com/azure/machine-learning/concept-workspace#associated-resources
- https://learn.microsoft.com/azure/azure-vmware/plan-private-cloud-deployment
