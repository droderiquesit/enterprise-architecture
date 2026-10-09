# platform/ — compute platforms, shared registry, messaging

Platform roots create **platforms** (clusters, environments, plans, hosts, accounts, pools, runtime storage)
and the data-plane RBAC workload identities need on them. They never create application resources (container
apps, web/function apps, Kubernetes workloads, container groups, Logic App workflows, Batch jobs), diagnostic
settings, or monitoring agents/extensions (ADR-0001 §3). Everything those owners need is published in the
root's `contract` output.

Database roots (`platform/data/**`) are documented separately by their owner.

## Roots (compute & shared)

| Root | Component / contract | Default state | Main resources |
|---|---|---|---|
| `shared/` | `platform-shared` | on (all profiles) | ACR (Standard, Entra-only; Premium + PE optional), AcrPull/AcrPush grants, platform Log Analytics workspace |
| `messaging/` | `platform-messaging` | on | Service Bus (Standard; Premium + PE optional), topic `order-events` + 3 subscriptions, queue `batch-items`, sender/receiver RBAC |
| `compute/aks/` | `platform-aks` | enterprise | private AKS 1.36, Entra + Azure RBAC, no local accounts, workload identity + federated credentials, CNI overlay/Cilium |
| `compute/containerapps/` | `platform-containerapps` | minimal+ | workload-profiles environment (Consumption + `dedicated-d4`), `ingress_mode` external (minimal) / internal (enterprise) |
| `compute/appservice/` | `platform-appservice` | enterprise | Linux P0v3, Windows P0v3, Windows-container P1v3 (off), Logic Apps WS1 (off) |
| `compute/functions/` | `platform-functions` | minimal+ | Flex Consumption FC1 + identity-only storage, separate Durable runtime storage, EP1/Y1 (off), Durable Task Scheduler (off, azapi) |
| `compute/vm/` | `platform-vm` | enterprise | Ubuntu 24.04 + Windows Server 2025 Azure Edition hosts, no public IP, Entra login, 19:00 UTC auto-shutdown |
| `compute/vmss/` | `platform-vmss` | enterprise | Flexible (hello-worker) + Uniform (hello-dbadapter, Manual upgrades), autoscale ceilings |
| `compute/batch/` | `platform-batch` | specialized/full | Batch account (private, Entra-only), no-public-IP simplified pool, identity auto-storage |
| `compute/servicefabric/` | `platform-servicefabric` | **disabled** | SF managed cluster Basic (3 nodes) |
| `compute/aro/` | `platform-aro` | **blocked** | ARO with managed identities (prerequisites in README) |
| `compute/specialized/` | `platform-specialized-compute` | all **disabled**, AVS **blocked** | confidential/dedicated-host/GPU VMs, Automation, Azure ML |

Shared code modules (not components): `modules/compute-runtime-storage` (hardened identity-only storage + PEs
+ RBAC) and `modules/compute-linux-baseline` (OS-only cloud-init, Python 3.13). Lab-wide modules
(`foundation/modules/{naming,tags,private-endpoint}`) are used for names, tags and private endpoints.

## Conventions

- Layout per ADR §12: `versions.tf`, `backend.tf` (partial `azurerm` backend), `providers.tf`
  (`storage_use_azuread = true`), `variables.tf` (`environment`, upstream contracts with only used fields,
  typed `settings` with `optional()` defaults and validations), `locals.tf` (naming + tags), `main.tf`,
  `outputs.tf` (`contract`), `tests/*.tftest.hcl` (mock providers, `command = plan`).
- Upstream contracts arrive as `foundation_network`, `foundation_identity`, `platform_shared` variables.
  Missing optional keys are handled with `try()`/`lookup()` (e.g. DNS zones, `aro-*` subnets); identities absent
  from the identity contract are skipped and reported in the contract where grants are optional.
- No secrets in contracts. VM/SF break-glass passwords come from `random_password` and live only in state.
- Every root's planned `contract` output is validated against `catalog/contracts/<name>.v1.schema.json` from
  the `terraform test -json -verbose` plan output.

## Provider gaps (AzAPI)

| Resource type | API version | Root | Reason |
|---|---|---|---|
| `Microsoft.DurableTask/schedulers`, `…/schedulers/taskHubs` | `2026-02-01` (GA) | `compute/functions` | azurerm 5.9 has no Durable Task Scheduler resources |

## Validation

```bash
for r in shared messaging compute/{aks,containerapps,appservice,functions,vm,vmss,batch,servicefabric,aro,specialized}; do
  (cd platform/$r && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test)
done
checkov -d platform/shared -d platform/messaging -d platform/compute --framework terraform
```

Nothing here has been deployed (no Azure credentials in the build sandbox): status is `implemented` at most.

## Cross-layer requirements (owned elsewhere)

- foundation-network: publish private DNS zone key **`batch`** (`privatelink.batch.azure.com`) for Batch
  private endpoints; associate the NAT gateway with `aks-nodes` before AKS creation (outbound
  `userAssignedNATGateway`) or a 0.0.0.0/0 UDR to the firewall; `aro-master`/`aro-worker` subnets when ARO is used.
- foundation-identity: identity **`hello-logicapps`** (Logic Apps Service Bus sender) — grants are skipped until it exists.
