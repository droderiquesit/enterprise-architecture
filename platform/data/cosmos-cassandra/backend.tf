# Partial configuration; the pipeline passes -backend-config (ADR-0001 §4).
# Key: <environment>/platform-db-cosmos-cassandra.tfstate
terraform {
  backend "azurerm" {}
}
