# Partial configuration; the pipeline passes -backend-config (ADR-0001 §4), key <env>/obs-kubernetes.tfstate.
terraform {
  backend "azurerm" {}
}
