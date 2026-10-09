locals {
  component   = "platform-db-mysql"
  workload    = "data-mysql"
  identities  = var.foundation_identity.identities
  vnet_mode   = var.settings.network_mode == "vnet"
  mysql_zone  = try(var.foundation_network.private_dns_zones["mysql"].id, null)
  server_uami = coalesce(var.settings.server_identity_id, try(azurerm_user_assigned_identity.server[0].id, null))
  admin_login = "ehadmin"
  kv_uri      = trimsuffix(var.foundation_identity.key_vault_uri, "/")

  # catalog/architecture-matrix.yaml databases.mysql-flexible
  databases = {
    adapter = { owner = "hello-dbadapter", boundary = "db adapter" }
  }

  # Datadog DBM (https://docs.datadoghq.com/database_monitoring/setup_mysql/azure/): performance_schema
  # must be ON (static parameter: server restart). events_statements_* consumers are ON by default on Azure.
  server_parameters = {
    performance_schema       = "ON"
    require_secure_transport = "ON"
  }

  grants = {
    for db, d in local.databases : db => [{
      identity_name = d.owner
      client_id     = local.identities[d.owner].client_id
      privileges    = "ALL PRIVILEGES ON `${db}`.*"
    }] if contains(keys(local.identities), d.owner)
  }
}

# Break-glass administrator password: ephemeral + write-only, so it never lands in state or plans.
# Recover by resetting it (az mysql flexible-server update --admin-password) as documented in README.
ephemeral "random_password" "admin" {
  length      = 32
  special     = true
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
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

resource "azurerm_user_assigned_identity" "server" {
  count               = var.settings.server_identity_id == null ? 1 : 0
  name                = "${module.naming.names.user_assigned_identity}-server"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = module.tags.tags
}

resource "azurerm_mysql_flexible_server" "this" {
  name                              = module.naming.unique.globally_unique
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  version                           = var.settings.version
  sku_name                          = var.settings.sku_name
  backup_retention_days             = var.settings.backup_retention_days
  geo_redundant_backup_enabled      = false
  public_network_access             = "Disabled"
  delegated_subnet_id               = local.vnet_mode ? var.foundation_network.subnets["mysql"].id : null
  private_dns_zone_id               = local.vnet_mode ? local.mysql_zone : null
  administrator_login               = local.admin_login
  administrator_password_wo         = ephemeral.random_password.admin.result
  administrator_password_wo_version = var.settings.admin_password_version
  tags                              = module.tags.tags

  storage {
    size_gb           = var.settings.storage_size_gb
    auto_grow_enabled = false
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.server_uami]
  }

  lifecycle {
    ignore_changes = [zone]
    precondition {
      condition     = !local.vnet_mode || local.mysql_zone != null
      error_message = "VNet mode needs foundation_network.private_dns_zones.mysql (privatelink.mysql.database.azure.com)."
    }
  }
}

resource "azurerm_mysql_flexible_server_active_directory_administrator" "this" {
  server_id   = azurerm_mysql_flexible_server.this.id
  identity_id = local.server_uami
  login       = var.settings.entra_admin.login
  object_id   = var.settings.entra_admin.object_id
  tenant_id   = var.environment.tenant_id
}

resource "azurerm_mysql_flexible_server_configuration" "this" {
  for_each            = local.server_parameters
  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = each.value
}

resource "azurerm_mysql_flexible_database" "this" {
  for_each            = local.databases
  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_0900_ai_ci"
}

module "private_endpoint" {
  count                = local.vnet_mode ? 0 : 1
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-mysql"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_mysql_flexible_server.this.id
  subresource_names    = ["mysqlServer"]
  private_dns_zone_ids = compact([local.mysql_zone])
  tags                 = module.tags.tags
}
