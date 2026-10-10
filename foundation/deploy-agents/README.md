# foundation-deploy-agents

- **Owner:** platform-engineering · **Component id:** `foundation-deploy-agents` · **State key:** `<env>/foundation-deploy-agents.tfstate`
- **Purpose:** self-hosted Azure DevOps agents *inside* the VNet so pipelines can reach private endpoints (state storage
  in phase 2, databases, AKS private API, ACA internal ingress) and read pipeline secrets from Delinea DSV with the
  `deploy-agent` managed identity (`tools/secrets/fetch.py`; IMDS, no stored credential).
- **Consumes:** `foundation-network` (`subnets["deploy-agents"]` incl. `delegation`, `spoke_vnet_id`),
  `foundation-identity` (`identities["deploy-agent"]`).
- **Produces:** `foundation-deploy-agents` v1 ([schema](../../catalog/contracts/foundation-deploy-agents.v1.schema.json)).
- **Status:** implemented (validate + mock tests). Not deployed.

## Modes

| `settings.mode` | Resources | Network setting needed |
|---|---|---|
| `vmss` (default) | Linux VMSS for Azure DevOps **"Azure Virtual Machine Scale Set agents"** | `deploy_agents_mode = "vmss"` (no delegation) |
| `managed-devops-pool` | Dev Center + project, `azurerm_managed_devops_pool` injected into `deploy-agents`, Reader + Network Contributor for the `DevOpsInfrastructure` principal on the VNet | `deploy_agents_mode = "managed-devops-pool"` (delegation `Microsoft.DevOpsInfrastructure/pools`) |

Preconditions fail the plan if the subnet delegation does not match the mode.

### VMSS requirements implemented (Learn: [scale set agents](https://learn.microsoft.com/azure/devops/pipelines/agents/scale-set-agents), verified 2026-10-09)

Uniform orchestration (`azurerm_linux_virtual_machine_scale_set`), `overprovision = false` (required), `upgrade_mode = "Manual"`
(required), no autoscale settings, no instance protection, `single_placement_group = true` (default, ≤ 100 agents),
`instances = 0` (Azure DevOps scales it; `instances`, the agent `extension` and the `__AzureDevOpsElasticPool*` tags are
ignored), Ubuntu 24.04 (`Canonical/ubuntu-24_04-lts/server`), no public IP, user-assigned identity `deploy-agent`,
SSH key only (`settings.vmss.admin_ssh_public_key` is required; password auth disabled).

After apply, create the agent pool in Azure DevOps: *Organization settings → Agent pools → Add pool → Azure virtual machine
scale set*, select the service connection (apply identity) and the scale set `contract.vmss_name`. The service connection
identity needs Contributor on the scale set (the apply identity has it at subscription scope).

### Managed DevOps Pools

**No AzAPI needed**: azurerm 5.9 provides `azurerm_managed_devops_pool`, `azurerm_dev_center`, `azurerm_dev_center_project`
(the "azurerm gap" in the original brief no longer exists). Inputs: `organization_url`, `projects`, `parallelism`,
`max_concurrency`, `sku_name` (default `Standard_D2ads_v5`), well-known image `ubuntu-24.04/latest`,
`devops_infrastructure_principal_id` (`az ad sp list --display-name DevOpsInfrastructure --query "[].id" -o tsv`).
The identity that creates the pool must be a member of the Azure DevOps organization with pool-management permission;
MDP uses `172.17.0.0/16` internally — do not use that range for VNets or private endpoints.

## How bootstrap works before private agents exist

1. **Bootstrap** runs from an operator workstation (`bootstrap/scripts/bootstrap.sh`): state storage is created with
   `public_network_access = Enabled`, firewall default **Deny**, operator IP in `operator_ip_ranges`.
2. **network / identity / governance / deploy-agents** run on **Microsoft-hosted agents**. Microsoft-hosted agents have
   no fixed IP and **cannot reach private endpoints** (they are outside your VNet). For these first runs add the hosted
   agent's current egress IP to `bootstrap` `operator_ip_ranges` *temporarily* (e.g. a pipeline step that discovers its IP
   and an operator re-applies bootstrap, or a short-lived `az storage account network-rule add` that the next bootstrap
   apply removes) — Terraform only needs ARM + the state blob, both reachable this way.
3. Once agents exist: set bootstrap `agent_subnet_ids = [contract.subnet_id]` (service endpoint `Microsoft.Storage` is on the
   subnet) → re-apply bootstrap, remove the temporary IPs, then point every pipeline stage at the private pool.
4. Phase 2: bootstrap `private_endpoint = {subnet_id, private_dns_zone_id}` + `public_network_access = "Disabled"`.
   From then on only VNet-connected agents (and operators via Bastion/VNet) can read or write state.

PR validation (fmt/validate/test with mocks) keeps running on Microsoft-hosted agents with **no service connection**.

## Settings (`components.foundation-deploy-agents`)

`mode`; `vmss.{sku=Standard_D2s_v5, admin_username=azdevops, admin_ssh_public_key, os_disk_type=StandardSSD_LRS, os_disk_size_gb=128,
zones=[], encryption_at_host=false, image}`; `managed_devops_pool.{organization_url, projects, parallelism=1, max_concurrency=2,
sku_name, image_name, devops_infrastructure_principal_id}`.

## Cost at defaults

VMSS at 0 instances: **USD 0 idle**. Each running Standard_D2s_v5 agent ≈ 0.096/h (≈ 70/month always-on) + 128 GB StandardSSD
(≈ 10/month while it exists). Azure DevOps keeps a configurable standby count (set it to 0 for a lab). MDP: you pay the VMs and
disks while agents run (no idle cost with stateless agents and no standby prediction) plus Azure DevOps parallel jobs.

## Teardown and data retention

Agents are stateless; destroy removes the scale set / pool. Remove the agent pool in Azure DevOps first (it will otherwise try to
scale a missing scale set). MDP: the subnet keeps a service association link until the pool is deleted.

## Known limitations

- `encryption_at_host` needs the `Microsoft.Compute/EncryptionAtHost` feature registered (off by default; checkov skip documented).
- The MDP well-known image name and `Standard_D2ads_v5` availability are region dependent; verify on first deploy.

## References

- https://learn.microsoft.com/azure/devops/pipelines/agents/scale-set-agents
- https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking
- https://learn.microsoft.com/azure/devops/pipelines/agents/hosted (Microsoft-hosted agent networking)

## GitHub Copilot code review pool

Copilot code review for Azure Repos runs only on Microsoft-hosted agents or a Managed DevOps Pool with the latest
Ubuntu image - **not** on self-hosted/VMSS pools and not on Windows images
([Microsoft Learn](https://learn.microsoft.com/azure/devops/repos/git/copilot-code-reviews#select-an-agent-pool)).
Set `settings.copilot_review_pool.enabled = true` (+ `organization_url`, `projects`) to create a dedicated pool
`<prefix>-mdp-...-copilot` (Ubuntu 24.04, Standard_D2ads_v5, max concurrency 2, Microsoft-hosted networking - no VNet
needed because reviews only read the repository). It is independent of `mode`, so the VMSS deploy agents stay as they
are. Then select it in **Organization settings > Repos > Repositories > GitHub Copilot code review > Compute pool**.
