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
}

# Observability Pipelines definition (datadog_observability_pipeline, log_pipeline = observability_pipelines).
# Credentials come from the environment (DD_API_KEY / DD_APP_KEY), exported by tools/secrets/fetch.py from Delinea DSV
# in the pipeline job; never in tfvars or state.
provider "datadog" {
  api_url = "https://api.${var.settings.datadog_site}/"
}
