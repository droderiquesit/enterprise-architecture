provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
}

provider "azapi" {
  subscription_id = var.environment.subscription_id
  tenant_id       = var.environment.tenant_id
}
