locals {
  component  = "platform-db-postgresql"
  workload   = "data-psql"
  identities = var.foundation_identity.identities
  vnet_mode  = var.settings.network_mode == "vnet"
  pg_zone    = try(var.foundation_network.private_dns_zones["postgres"].id, null)

  # catalog/architecture-matrix.yaml databases.postgresql-flexible
  databases = {
    catalog = { owner = "hello-catalog-api", boundary = "db catalog", schema = "catalog" }
    adapter = { owner = "hello-dbadapter", boundary = "db adapter (hello-dbadapter-postgresql)", schema = "adapter" }
  }

  # Server parameters required by Datadog Database Monitoring on Flexible Server
  # (https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/). pg_stat_statements is
  # preloaded by default on Flexible Server, so shared_preload_libraries is left at the service default.
  server_parameters = {
    "azure.extensions"                 = join(",", distinct(concat(["PG_STAT_STATEMENTS"], [for e in var.settings.extra_extensions : upper(e)])))
    "track_activity_query_size"        = "4096"
    "pg_stat_statements.track"         = "all"
    "pg_stat_statements.max"           = "10000"
    "pg_stat_statements.track_utility" = "off"
    "track_io_timing"                  = "on"
    "require_secure_transport"         = "on"
  }

  grants = {
    for db, d in local.databases : db => [{
      identity_name = d.owner
      object_id     = local.identities[d.owner].principal_id
      privileges    = "owner-of-schema"
      schema        = d.schema
    }] if contains(keys(local.identities), d.owner)
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

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = module.naming.unique.globally_unique
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = var.settings.version
  sku_name                      = var.settings.sku_name
  storage_mb                    = var.settings.storage_mb
  storage_tier                  = var.settings.storage_tier
  auto_grow_enabled             = false
  backup_retention_days         = var.settings.backup_retention_days
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = false
  delegated_subnet_id           = local.vnet_mode ? var.foundation_network.subnets["postgres"].id : null
  private_dns_zone_id           = local.vnet_mode ? local.pg_zone : null
  tags                          = module.tags.tags

  # Entra-only: password authentication disabled, so no administrator password exists.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.environment.tenant_id
  }

  lifecycle {
    # Azure assigns a zone when none is requested; do not churn on it.
    ignore_changes = [zone]
    precondition {
      condition     = !local.vnet_mode || local.pg_zone != null
      error_message = "VNet mode needs foundation_network.private_dns_zones.postgres (privatelink.postgres.database.azure.com)."
    }
  }
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = var.environment.tenant_id
  object_id           = var.settings.entra_admin.object_id
  principal_name      = var.settings.entra_admin.principal_name
  principal_type      = var.settings.entra_admin.principal_type
}

resource "azurerm_postgresql_flexible_server_configuration" "this" {
  for_each  = local.server_parameters
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  for_each  = local.databases
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

module "private_endpoint" {
  count                = local.vnet_mode ? 0 : 1
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-psql"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_postgresql_flexible_server.this.id
  subresource_names    = ["postgresqlServer"]
  private_dns_zone_ids = compact([local.pg_zone])
  tags                 = module.tags.tags
}

# ---------------------------------------------------------------- Elastic Cluster (optional)
resource "azurerm_postgresql_flexible_server" "elastic" {
  count                         = var.settings.elastic_cluster.enabled ? 1 : 0
  name                          = "${module.naming.unique.globally_unique}-ec"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = var.settings.version
  sku_name                      = var.settings.elastic_cluster.sku_name
  storage_mb                    = var.settings.elastic_cluster.storage_mb
  backup_retention_days         = var.settings.backup_retention_days
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = false
  tags                          = merge(module.tags.tags, { service = "hello-dbadapter" })

  cluster {
    size                  = var.settings.elastic_cluster.node_count
    default_database_name = "adapter"
  }

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.environment.tenant_id
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "elastic" {
  count               = var.settings.elastic_cluster.enabled ? 1 : 0
  server_name         = azurerm_postgresql_flexible_server.elastic[0].name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = var.environment.tenant_id
  object_id           = var.settings.entra_admin.object_id
  principal_name      = var.settings.entra_admin.principal_name
  principal_type      = var.settings.entra_admin.principal_type
}

resource "azurerm_postgresql_flexible_server_configuration" "elastic" {
  for_each  = var.settings.elastic_cluster.enabled ? local.server_parameters : {}
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.elastic[0].id
  value     = each.value
}

# Elastic clusters do not support VNet injection; private access is via Private Link only.
module "private_endpoint_elastic" {
  count                = var.settings.elastic_cluster.enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-psql-ec"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_postgresql_flexible_server.elastic[0].id
  subresource_names    = [var.settings.elastic_cluster.pe_group_id]
  private_dns_zone_ids = compact([local.pg_zone])
  tags                 = module.tags.tags
}
