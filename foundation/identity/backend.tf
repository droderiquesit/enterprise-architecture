# Partial configuration (ADR-0001 §4). The pipeline passes:
#   -backend-config="storage_account_name=<bootstrap.state_storage_account_name>"
#   -backend-config="container_name=tfstate" -backend-config="key=<env>/foundation-identity.tfstate"
#   -backend-config="use_azuread_auth=true" -backend-config="use_oidc=true"
terraform {
  backend "azurerm" {}
}
