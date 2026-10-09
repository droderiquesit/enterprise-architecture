terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
    # Bootstrap only (ADR-0001 §2): Entra app registration for the Datadog Azure integration.
    # 3.10.0 is the latest release (published 2026-09-24, checked against registry.terraform.io on 2026-10-09);
    # Datadog secretless auth needs >= 3.7.0.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
}
