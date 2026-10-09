# Bootstrap starts with LOCAL state (scripts/bootstrap.sh writes a temporary backend_override.tf with
# `backend "local" {}`), creates the state storage account, then migrates into it:
#   terraform init -migrate-state -force-copy \
#     -backend-config="resource_group_name=<rg>" -backend-config="storage_account_name=<account>" \
#     -backend-config="container_name=tfstate" -backend-config="key=<env>/bootstrap.tfstate" \
#     -backend-config="use_azuread_auth=true"
# See README.md "First run" for the exact sequence.
terraform {
  backend "azurerm" {}
}
