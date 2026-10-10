terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
    # provider gap (catalog/provider-gaps.yaml, service vm-applications): azurerm_shared_image_gallery has no
    # `identity` block in 5.9.0; the gallery's user-assigned identity is what lets it publish from a private
    # storage account with plain blob URLs (no SAS).
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }
}
