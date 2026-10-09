# Partial configuration; the pipeline passes -backend-config (ADR-0001 §4), key <env>/obs-telemetry-transport.tfstate.
terraform {
  backend "azurerm" {}
}
