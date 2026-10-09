# Partial configuration (ADR-0001 §4): the pipeline passes storage account, container, key (<env>/foundation-secrets.tfstate),
# use_azuread_auth and use_oidc via -backend-config. The state holds only the rendered desired state (no secrets).
terraform {
  backend "azurerm" {}
}
