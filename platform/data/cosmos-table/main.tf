locals {
  component  = "platform-db-cosmos-table"
  workload   = "data-ctable"
  identities = var.foundation_identity.identities
  autoscale  = var.settings.capacity_mode == "provisioned" ? [var.settings.autoscale_max_throughput] : []

  # catalog/architecture-matrix.yaml databases.cosmos-table
  owner    = "hello-dbadapter"
  boundary = "table adapterrecords"

  owner_principal_id = try(local.identities[local.owner].principal_id, null)
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

module "account" {
  source                       = "../../modules/data-cosmos-account"
  name                         = module.naming.unique.cosmos
  resource_group_name          = azurerm_resource_group.this.name
  location                     = azurerm_resource_group.this.location
  tags                         = module.tags.tags
  api                          = "table"
  capacity_mode                = var.settings.capacity_mode
  free_tier_enabled            = var.settings.free_tier_enabled
  local_authentication_enabled = false # Entra data-plane RBAC is supported for the Table API
  backup_type                  = "Continuous"
  private_endpoint = {
    enabled             = var.settings.private_endpoint_enabled
    subnet_id           = var.foundation_network.subnets["private-endpoints"].id
    private_dns_zone_id = try(var.foundation_network.private_dns_zones["cosmos_table"].id, null)
    name                = "${module.naming.names.private_endpoint}-cosmos-table"
  }
}

resource "azurerm_cosmosdb_table" "adapterrecords" {
  name                = "adapterrecords"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = module.account.name

  dynamic "autoscale_settings" {
    for_each = local.autoscale
    content {
      max_throughput = autoscale_settings.value
    }
  }
}

# AzAPI gap: azurerm has no resource for Cosmos DB *Table* data-plane role assignments
# (tableRoleAssignments); see catalog/provider-gaps.yaml request in README.
# Built-in "Cosmos DB Built-in Data Contributor" table role definition ID ...0002.
resource "azapi_resource" "table_data_contributor" {
  count     = local.owner_principal_id == null ? 0 : 1
  type      = "Microsoft.DocumentDB/databaseAccounts/tableRoleAssignments@2026-03-15"
  name      = uuidv5("url", "${module.account.id}/tableRoleAssignments/${local.owner}")
  parent_id = module.account.id
  body = {
    properties = {
      principalId      = local.owner_principal_id
      roleDefinitionId = "${module.account.id}/tableRoleDefinitions/00000000-0000-0000-0000-000000000002"
      scope            = module.account.id
    }
  }
}
