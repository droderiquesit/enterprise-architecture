provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
  # pipeline identities hold no provider-registration rights (bootstrap registers providers)
  resource_provider_registrations = "none"
}

provider "azapi" {
  subscription_id = var.environment.subscription_id
  tenant_id       = var.environment.tenant_id
  # pipeline identities hold no provider-registration rights (bootstrap registers providers)
  skip_provider_registration = true
}
