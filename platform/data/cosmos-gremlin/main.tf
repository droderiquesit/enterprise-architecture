locals {
  component = "platform-db-cosmos-gremlin"
  workload  = "data-gremlin"
  autoscale = var.settings.capacity_mode == "provisioned" ? [var.settings.autoscale_max_throughput] : []

  # catalog/architecture-matrix.yaml databases.cosmos-gremlin
  owner    = "hello-dbadapter"
  boundary = "db adapter / graph records"

  # Exception (README): the Gremlin wire protocol authenticates with the account key; Cosmos DB does
  # not natively accept managed-identity tokens on the Gremlin endpoint.
  key_secret_id = lookup(var.foundation_identity.secrets.refs, var.settings.key_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.key_secret_name}#value")
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
  api                          = "gremlin"
  capacity_mode                = var.settings.capacity_mode
  free_tier_enabled            = var.settings.free_tier_enabled
  local_authentication_enabled = true # exception: key auth (see README)
  backup_type                  = "Continuous"
  private_endpoint = {
    enabled             = var.settings.private_endpoint_enabled
    subnet_id           = var.foundation_network.subnets["private-endpoints"].id
    private_dns_zone_id = try(var.foundation_network.private_dns_zones["cosmos_gremlin"].id, null)
    name                = "${module.naming.names.private_endpoint}-cosmos-gremlin"
  }
}

resource "azurerm_cosmosdb_gremlin_database" "adapter" {
  name                = "adapter"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = module.account.name
}

resource "azurerm_cosmosdb_gremlin_graph" "records" {
  name                  = "records"
  resource_group_name   = azurerm_resource_group.this.name
  account_name          = module.account.name
  database_name         = azurerm_cosmosdb_gremlin_database.adapter.name
  partition_key_path    = "/pk"
  partition_key_version = 2

  dynamic "autoscale_settings" {
    for_each = local.autoscale
    content {
      max_throughput = autoscale_settings.value
    }
  }
}
