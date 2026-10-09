# Partial configuration (ADR-0001 §4). The pipeline passes storage_account_name,
# container_name = "tfstate", key = "<environment>/foundation-pr-reviewer.tfstate",
# use_azuread_auth = true and use_oidc = true via -backend-config.
terraform {
  backend "azurerm" {}
}
