locals {
  component  = "platform-db-cosmos-nosql"
  workload   = "data-nosql"
  identities = var.foundation_identity.identities
  autoscale  = var.settings.capacity_mode == "provisioned" ? [var.settings.autoscale_max_throughput] : []

  # catalog/architecture-matrix.yaml databases.cosmos-nosql
  databases = {
    inventory = {
      owner      = "hello-inventory-api"
      boundary   = "db inventory / container items"
      containers = { items = { partition_key = "/sku" } }
    }
    adapter = {
      owner      = "hello-dbadapter"
      boundary   = "db adapter / container records (hello-dbadapter-cosmos-nosql)"
      containers = { records = { partition_key = "/id" } }
    }
  }

  containers = merge([
    for db, d in local.databases : {
      for c, cfg in d.containers : "${db}/${c}" => { database = db, name = c, partition_key = cfg.partition_key }
    }
  ]...)

  # Cosmos DB Built-in Data Contributor (data-plane RBAC, not Azure RBAC).
  data_contributor_role_id = "${module.account.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  rbac = {
    for db, d in local.databases : db => {
      identity_name = d.owner
      principal_id  = local.identities[d.owner].principal_id
      scope         = "${module.account.id}/dbs/${db}"
    } if contains(keys(local.identities), d.owner)
  }
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
  api                          = "nosql"
  capacity_mode                = var.settings.capacity_mode
  free_tier_enabled            = var.settings.free_tier_enabled
  local_authentication_enabled = false
  backup_type                  = "Continuous"
  consistency_level            = var.settings.consistency_level
  private_endpoint = {
    enabled             = var.settings.private_endpoint_enabled
    subnet_id           = var.foundation_network.subnets["private-endpoints"].id
    private_dns_zone_id = try(var.foundation_network.private_dns_zones["cosmos_sql"].id, null)
    name                = "${module.naming.names.private_endpoint}-cosmos-sql"
  }
}

resource "azurerm_cosmosdb_sql_database" "this" {
  for_each            = local.databases
  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  account_name        = module.account.name
}

resource "azurerm_cosmosdb_sql_container" "this" {
  for_each              = local.containers
  name                  = each.value.name
  resource_group_name   = azurerm_resource_group.this.name
  account_name          = module.account.name
  database_name         = azurerm_cosmosdb_sql_database.this[each.value.database].name
  partition_key_paths   = [each.value.partition_key]
  partition_key_kind    = "Hash"
  partition_key_version = 2

  dynamic "autoscale_settings" {
    for_each = local.autoscale
    content {
      max_throughput = autoscale_settings.value
    }
  }
}

resource "azurerm_cosmosdb_sql_role_assignment" "this" {
  for_each            = local.rbac
  resource_group_name = azurerm_resource_group.this.name
  account_name        = module.account.name
  role_definition_id  = local.data_contributor_role_id
  principal_id        = each.value.principal_id
  scope               = each.value.scope
}
