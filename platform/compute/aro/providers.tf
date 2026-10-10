provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
  # Pipeline identities hold no provider-registration rights; bootstrap/scripts/bootstrap.sh registers providers.
  resource_provider_registrations = "none"
}

# Read-only use: the cluster's managed OIDC issuer (clusterProfile.oidcIssuer, not exposed by azurerm 5.9).
provider "azapi" {
  subscription_id            = var.environment.subscription_id
  tenant_id                  = var.environment.tenant_id
  skip_provider_registration = true # same reason as resource_provider_registrations above
}
