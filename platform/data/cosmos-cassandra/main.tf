locals {
  component = "platform-db-cosmos-cassandra"
  workload  = "data-cass"
  autoscale = var.settings.capacity_mode == "provisioned" ? [var.settings.autoscale_max_throughput] : []

  # catalog/architecture-matrix.yaml databases.cosmos-cassandra
  owner    = "hello-dbadapter"
  boundary = "keyspace adapter"

  # Exception (README): CQL drivers authenticate with the account name + key. ARM exposes
  # cassandraRoleAssignments, but no documented driver-side Entra flow was found, so the key is
  # stored out-of-band in Delinea DSV and only the dsv:// reference is published.
  key_secret_id = lookup(var.foundation_identity.secrets.refs, var.settings.connection_string_secret_name, "dsv://${var.foundation_identity.secrets.base_path}/${var.settings.connection_string_secret_name}#value")
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
  api                          = "cassandra"
  capacity_mode                = var.settings.capacity_mode
  free_tier_enabled            = var.settings.free_tier_enabled
  local_authentication_enabled = true       # exception: key auth (see README)
  backup_type                  = "Periodic" # continuous backup is not supported for the Cassandra API
  private_endpoint = {
    enabled             = var.settings.private_endpoint_enabled
    subnet_id           = var.foundation_network.subnets["private-endpoints"].id
    private_dns_zone_id = try(var.foundation_network.private_dns_zones["cosmos_cassandra"].id, null)
    name                = "${module.naming.names.private_endpoint}-cosmos-cass"
  }
}

resource "azurerm_cosmosdb_cassandra_keyspace" "adapter" {
  name                = "adapter"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = module.account.name
}

# ARM-managed table so the adapter needs no DDL rights; synthetic records only.
resource "azurerm_cosmosdb_cassandra_table" "records" {
  name                  = "records"
  cassandra_keyspace_id = azurerm_cosmosdb_cassandra_keyspace.adapter.id

  schema {
    column {
      name = "id"
      type = "text"
    }
    column {
      name = "payload"
      type = "text"
    }
    column {
      name = "created_at"
      type = "timestamp"
    }
    partition_key {
      name = "id"
    }
  }

  dynamic "autoscale_settings" {
    for_each = local.autoscale
    content {
      max_throughput = autoscale_settings.value
    }
  }
}
