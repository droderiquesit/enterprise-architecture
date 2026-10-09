provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
  # Providers are registered explicitly by scripts/bootstrap.sh (idempotent, auditable list).
  resource_provider_registrations = "none"
}

provider "azuread" {
  tenant_id = var.environment.tenant_id
}
