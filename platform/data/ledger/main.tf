locals {
  component  = "platform-db-ledger"
  workload   = "data-ledger"
  identities = var.foundation_identity.identities

  # catalog/architecture-matrix.yaml databases.confidential-ledger. Ledger collections are created
  # implicitly by the first write with a collectionId (data plane), so they are documented, not ARM-managed.
  collections = {
    "order-audit" = { owner = "hello-functions", boundary = "collection order-audit" }
    "adapter"     = { owner = "hello-dbadapter", boundary = "collection adapter (hello-dbadapter-ledger)" }
  }
  writers = distinct([for c in values(local.collections) : c.owner if contains(keys(local.identities), c.owner)])
}

module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = local.workload
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = local.component
  layer       = "platform"
  domain      = "data"
  tier        = "database"
}

resource "azurerm_resource_group" "this" {
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

# Azure Confidential Ledger exposes only its public, TLS-1.3 enclave endpoint: no Private Link support
# was found in the service documentation, so this component is a recorded private-networking exception.
resource "azurerm_confidential_ledger" "this" {
  name                = substr(module.naming.unique.globally_unique, 0, 24)
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  ledger_type         = var.settings.ledger_type
  tags                = module.tags.tags

  azuread_based_service_principal {
    principal_id     = var.settings.administrator_object_id
    tenant_id        = var.environment.tenant_id
    ledger_role_name = "Administrator"
  }

  dynamic "azuread_based_service_principal" {
    for_each = toset(local.writers)
    content {
      principal_id     = local.identities[azuread_based_service_principal.value].principal_id
      tenant_id        = var.environment.tenant_id
      ledger_role_name = "Contributor"
    }
  }
}
