# Credentials from DD_API_KEY / DD_APP_KEY (pipeline: Key Vault -> env). Never in tfvars.
provider "datadog" {
  api_url = "https://api.${var.datadog_site}/"
}

# Azure: only diagnostic settings (and, when enabled, agent extensions) on EXISTING resources.
provider "azurerm" {
  features {}
  subscription_id     = var.azure_subscription_id
  storage_use_azuread = true
}

# Required by the azure-integration module (native mode only); unused in app_registration mode.
provider "azapi" {
  subscription_id = var.azure_subscription_id
}
