locals {
  component  = "platform-db-redis"
  workload   = "data-redis"
  identities = var.foundation_identity.identities

  # catalog/architecture-matrix.yaml databases.managed-redis (cache-aside, not durable)
  clients = {
    "hello-catalog-api" = { key_prefix = "catalog:", role = "owner" }
    "hello-dbadapter"   = { key_prefix = "adapter:", role = "adapter" }
  }
  access = { for k, v in local.clients : k => local.identities[k].principal_id if contains(keys(local.identities), k) }
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

# Azure Managed Redis (Microsoft.Cache/redisEnterprise). azurerm_redis_cache (Azure Cache for Redis)
# is deliberately not used: it is on a retirement path.
resource "azurerm_managed_redis" "this" {
  name                      = module.naming.unique.globally_unique
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  sku_name                  = var.settings.sku_name
  high_availability_enabled = var.settings.high_availability_enabled
  public_network_access     = "Disabled"
  tags                      = module.tags.tags

  default_database {
    access_keys_authentication_enabled = false       # Entra ID only
    client_protocol                    = "Encrypted" # TLS
    clustering_policy                  = var.settings.clustering_policy
    eviction_policy                    = var.settings.eviction_policy
    # No persistence: the cache is rebuildable from the system of record.
  }
}

resource "azurerm_managed_redis_access_policy_assignment" "this" {
  for_each         = local.access
  managed_redis_id = azurerm_managed_redis.this.id
  object_id        = each.value
}

module "private_endpoint" {
  count                = var.settings.private_endpoint_enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-redis"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_managed_redis.this.id
  subresource_names    = ["redisEnterprise"]
  private_dns_zone_ids = compact([try(var.foundation_network.private_dns_zones["redis"].id, null)])
  tags                 = module.tags.tags
}
