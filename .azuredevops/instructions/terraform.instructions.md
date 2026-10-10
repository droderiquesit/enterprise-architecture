---
applyTo: "**/*.tf,**/*.tftest.hcl"
---
# Terraform

- Providers exactly as `versions.yaml` (azurerm `~> 5.9`, azapi only for gaps listed in `catalog/provider-gaps.yaml`).
- Root layout per ADR-0001 section 12; `backend "azurerm" {}` partial config; `output "contract"` must match
  `catalog/contracts/<name>.v<major>.schema.json` and contain no secrets.
- Flag: removed resources without a `moved {}` block, removed `prevent_destroy`, `lifecycle.ignore_changes` on security
  attributes, new `azurerm_role_assignment` broader than needed (scope, role), `public_network_access*` enabled,
  NSG rules allowing `*`/`Internet`, `terraform_remote_state`, `random_*` used for names (use `foundation/modules/naming`).
- `var.settings` is a typed object with `optional(..., default)` and validations; upstream contracts are typed variables.
- Tests: `mock_provider` + `command = plan` runs asserting planned values; computed ids mocked in valid shapes.
