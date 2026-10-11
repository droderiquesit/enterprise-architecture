# Partial configuration: the pipeline passes -backend-config (ADR-0001 §4).
# The state holds only the rendered desired state (no secrets).
terraform {
  backend "azurerm" {}
}
