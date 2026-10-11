terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
    # Bootstrap only (ADR-0001 §2): Datadog integration app registration; secretless auth needs >= 3.7.0.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
}
