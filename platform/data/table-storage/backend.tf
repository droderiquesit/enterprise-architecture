# Partial configuration; the pipeline passes -backend-config (ADR-0001 §4).
# Key: <environment>/platform-db-table-storage.tfstate
terraform {
  backend "azurerm" {}
}
