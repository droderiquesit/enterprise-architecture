# Foundation layer

Owner: **platform-engineering** (principal Azure platform engineer for bootstrap + foundation).
Binding contract: [ADR-0001](../docs/architecture/ADR-0001-design-contract.md) §3, §4, §5, §7, §8.

The foundation layer owns everything the lab's platforms and applications sit *on*: networks, DNS, the lab
workload identities + Delinea DSV secret access (no Azure Key Vault), cost/policy guard rails, private pipeline agents and optional edge services.
It never owns compute platforms, databases or application settings (those are `platform/` and `applications/`).

| Component (catalog id) | Root | Produces contract | Consumes | Default profile |
|---|---|---|---|---|
| `foundation-network` | [`network/`](network/README.md) | `foundation-network` v1 | — | all |
| `foundation-identity` | [`identity/`](identity/README.md) | `foundation-identity` v2 | — | all |
| `foundation-secrets` | [`secrets/`](secrets/README.md) | — (output `dsv_desired_state`, converged by `tools/secrets/dsv_apply.py`) | identity | all |
| `foundation-governance` | [`governance/`](governance/README.md) | `foundation-governance` v1 | — | all |
| `foundation-deploy-agents` | [`deploy-agents/`](deploy-agents/README.md) | `foundation-deploy-agents` v1 | network, identity | enterprise, full, specialized |
| `foundation-edge` | [`edge/`](edge/README.md) | `foundation-edge` v1 | network (after `foundation-secrets`) | enterprise, full (all edge parts off unless enabled) |
| `foundation-pr-reviewer` | [`pr-reviewer/`](pr-reviewer/README.md) | `foundation-pr-reviewer` v1 | identity (+ network, optional) | enterprise, full |

Shared modules (code reuse, not ownership — ADR §3 rule 5):

| Module | Purpose | Interface |
|---|---|---|
| [`modules/naming`](modules/naming/README.md) | CAF names `<prefix>-<type>-<workload>-<env>-<region>` + deterministic 5-char suffix for global names | frozen |
| [`modules/tags`](modules/tags/README.md) | ADR §7 required tag set | frozen |
| [`modules/private-endpoint`](modules/private-endpoint/README.md) | private endpoint + DNS zone group (zones come from `foundation-network`) | frozen |

## Apply order

```
bootstrap (manual, once)            -> state storage, pipeline identities
  foundation-network                -> VNets, subnets, NSGs, NAT/route tables, private DNS zones
    foundation-identity             -> workload identities, DSV secret refs               (independent)
      foundation-secrets            -> DSV users + least-privilege permissions (dsv_apply.py, needs identity)
    foundation-governance           -> budget, action group, policy assignments          (independent)
    foundation-deploy-agents        -> VMSS agents or Managed DevOps Pool                 (needs network + identity)
    foundation-edge                 -> App Gateway / Front Door / APIM / Firewall / Bastion (needs network; after secrets)
    foundation-pr-reviewer          -> automated PR reviewer Function (needs identity; network optional)
platform-* -> applications -> observability lab roots
```

Switching egress to Azure Firewall is a two-pass change (see [network README](network/README.md#switching-egress-to-azure-firewall)).

## Conventions every foundation root follows

- Layout per ADR §12; `resource_provider_registrations = "none"` because `bootstrap/scripts/bootstrap.sh` registers providers.
- Upstream contracts arrive as variables named after the contract, typed with only the fields used (ADR §5).
- Tags from `modules/tags` on every taggable resource; names from `modules/naming`; no `random_*` names.
- Private by default: PaaS behind private endpoints, default outbound access disabled on every subnet,
  explicit egress (NAT Gateway or firewall) only for subnets that need it, inbound internet denied by NSG.
- No secret values in contracts: Delinea DSV holds every value (set out-of-band or by `tools/secrets/publish.py`); contracts carry `dsv://` references (ADR-0001 section 14).
- No AzAPI in foundation: azurerm 5.9 covers everything here (including `azurerm_managed_devops_pool`).

## Validation and status

Repo-wide Terraform checks are in the [root README](../README.md); additionally `checkov -d bootstrap -d foundation --framework terraform`.
All foundation roots are **implemented** (ADR §11: static validation + mock-provider tests); nothing has been deployed yet.

## Cost at defaults

≈ USD 50/month, almost all `foundation-network` (NAT Gateway, public IP, ~27 private DNS zones); the other roots are ≈ 0 idle.
Per-root figures (including edge components when enabled) are in each root README.
