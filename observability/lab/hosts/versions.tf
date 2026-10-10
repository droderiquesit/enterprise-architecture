terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
    # provider gap (catalog/provider-gaps.yaml, vm-applications): the Compute Gallery's user-assigned identity
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }
}
