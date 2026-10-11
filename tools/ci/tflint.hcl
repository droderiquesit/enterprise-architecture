# TFLint configuration of the CI legs (tools/validate/terraform.sh passes it with --config when tflint is installed).
# Bundled terraform ruleset, recommended preset. Warnings fail for bootstrap/foundation/platform; other roots fail on
# errors only (deployment roots declare consumed-contract variables they do not all read).
# The azurerm ruleset (terraform-linters/tflint-ruleset-azurerm) is opt-in: add a plugin block with a pinned version
# and `source`, then `tflint --init` (plugins are signature-verified); not enabled because its rules target azurerm
# 4.x and this repository pins azurerm 5.9.0.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
