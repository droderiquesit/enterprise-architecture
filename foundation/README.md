# Foundation layer

Owner: **platform-engineering** (principal Azure platform engineer for bootstrap + foundation).
Binding contract: [ADR-0001](../docs/architecture/ADR-0001-design-contract.md) §3, §4, §5, §7, §8.

The foundation layer owns everything the lab's platforms and applications sit *on*: networks, DNS, the lab
workload identities + Delinea DSV secret access (no Azure Key Vault), cost/policy guard rails, private pipeline agents and optional edge services.
It never owns compute platforms, databases or application settings (those are `platform/` and `applications/`).

| Component (catalog id) | Root | Produces contract | Consumes | Default profile |
|---|---|---|---|---|
| `foundation-network` | [`network/`](network/README.md) | `foundation-network` v1 | — | all |
| `foundation-identity` | [`identity/`](identity/README.md) | `foundation-identity` v1 | `foundation-network` | all |
| `foundation-governance` | [`governance/`](governance/README.md) | `foundation-governance` v1 | — | all |
| `foundation-deploy-agents` | [`deploy-agents/`](deploy-agents/README.md) | `foundation-deploy-agents` v1 | network, identity | enterprise, full, specialized |
| `foundation-edge` | [`edge/`](edge/README.md) | `foundation-edge` v1 | network, identity | enterprise (all edge parts off unless enabled) |

Shared modules (code reuse, not ownership — ADR §3 rule 5):

| Module | Purpose | Interface |
|---|---|---|
| [`modules/naming`](modules/naming/main.tf) | CAF names `<prefix>-<type>-<workload>-<env>-<region>` + deterministic 5-char suffix for global names | frozen |
| [`modules/tags`](modules/tags/main.tf) | ADR §7 required tag set | frozen |
| [`modules/private-endpoint`](modules/private-endpoint/main.tf) | private endpoint + DNS zone group (zones come from `foundation-network`) | frozen |

## Apply order

```
bootstrap (manual, once)            -> state storage, pipeline identities
  foundation-network                -> VNets, subnets, NSGs, NAT/route tables, private DNS zones
    foundation-identity             -> workload identities, DSV secret refs               (independent)
      foundation-secrets            -> DSV users + least-privilege permissions (dsv_apply.py, needs identity)
    foundation-governance           -> budget, action group, policy assignments          (independent)
    foundation-deploy-agents        -> VMSS agents or Managed DevOps Pool                 (needs network + identity)
    foundation-edge                 -> App Gateway / Front Door / APIM / Firewall / Bastion (needs network)
platform-* -> applications -> observability lab roots
```

`network -> identity -> {governance, deploy-agents, edge}`. Governance has no inputs and may run in parallel with
network. Switching egress to Azure Firewall is a two-pass change (see [network README](network/README.md#switching-egress-to-azure-firewall)).

## Conventions every foundation root follows

- Layout per ADR §12: `versions.tf`, `backend.tf` (`backend "azurerm" {}` partial config, key `<env>/<component>.tfstate`),
  `providers.tf` (`storage_use_azuread = true`, `resource_provider_registrations = "none"` — providers are registered by
  `bootstrap/scripts/bootstrap.sh`), `variables.tf` (`environment`, typed `settings`, upstream contracts), `outputs.tf`
  (`output "contract"`), `tests/*.tftest.hcl` (mock providers, `command = plan`).
- Upstream contracts arrive as variables named after the contract (`foundation_network`, `foundation_identity`) with only the
  fields used; `terraform_remote_state` is never used.
- Tags from `modules/tags` on every taggable resource; names from `modules/naming`; no `random_*` names.
- Private by default: PaaS behind private endpoints, default outbound access disabled on every subnet,
  explicit egress (NAT Gateway or firewall) only for subnets that need it, inbound internet denied by NSG.
- No secret values in contracts: Delinea DSV holds every value (set out-of-band or by `tools/secrets/publish.py`); contracts carry `dsv://` references (ADR-0001 section 14).
- Provider pins: `azurerm ~> 5.9`, `time ~> 0.14` (governance). **No AzAPI is used in foundation**: Managed DevOps Pools,
  Dev Center and every other resource here are covered by azurerm 5.9 (`azurerm_managed_devops_pool` exists).

## Validation (what was actually run)

```bash
for r in bootstrap foundation/network foundation/identity foundation/governance foundation/deploy-agents foundation/edge; do
  (cd $r && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test)
done
python3 -m pytest foundation/identity/tests -q
checkov -d bootstrap --framework terraform --quiet --compact
checkov -d foundation --framework terraform --quiet --compact
```

Status (ADR §11): all foundation roots are **implemented** (static validation + mock-provider tests). Nothing here has been
deployed from this repository yet; no evidence files exist.

## Cost profile at defaults (approximate list prices, USD/month, swedencentral, Oct 2026 — verify with the pricing calculator)

| Component | Default footprint | ≈ USD/month |
|---|---|---|
| network | single spoke, 1 NAT Gateway + 1 Standard public IP, ~27 private DNS zones | 33 (NAT) + 4 (IP) + 14 (zones) + data processing ≈ **50** |
| identity | 18 user-assigned identities (free) | **0** |
| secrets | no Azure resources (Delinea DSV subscription is separate) | **0** |
| governance | budget, action group (email), 5 policy assignments | **0** |
| deploy-agents | VMSS at 0 instances (Azure DevOps scales it) | **0 idle**; ≈ 70 per always-on D2s_v5 agent |
| edge | everything disabled | **0** (see edge README for per-component prices) |
