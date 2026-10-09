locals {
  component  = "platform-db-cassandra-mi"
  workload   = "data-cassmi"
  enabled    = var.settings.enabled
  subnet_id  = try(var.foundation_network.subnets["cassandra-mi"].id, null)
  role_scope = var.settings.network_contributor_scope == "vnet" ? var.foundation_network.spoke_vnet_id : local.subnet_id
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

# default_admin_password is required by the cluster resource and has no write-only variant: the value comes from
# Delinea DSV (cassandra-mi-admin-password) as a pipeline input (var.admin_password) and is stored in state.

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

# The Azure Cosmos DB service principal deploys the datacenter VMSS into the delegated subnet.
resource "azurerm_role_assignment" "cosmosdb_network" {
  count                = local.enabled ? 1 : 0
  scope                = local.role_scope
  role_definition_name = "Network Contributor"
  principal_id         = var.settings.cosmosdb_service_principal_object_id
  principal_type       = "ServicePrincipal"
  description          = "Managed Instance for Apache Cassandra: subnets/join/action for datacenter deployment."
}

resource "azurerm_cosmosdb_cassandra_cluster" "this" {
  count                          = local.enabled ? 1 : 0
  name                           = module.naming.names.cassandra_mi
  resource_group_name            = azurerm_resource_group.this[0].name
  location                       = azurerm_resource_group.this[0].location
  delegated_management_subnet_id = local.subnet_id
  default_admin_password         = var.admin_password
  version                        = var.settings.cassandra_version
  authentication_method          = "Cassandra"
  repair_enabled                 = true
  hours_between_backups          = 24
  tags                           = module.tags.tags

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_role_assignment.cosmosdb_network]

  lifecycle {
    precondition {
      condition     = var.admin_password != null
      error_message = "admin_password (DSV cassandra-mi-admin-password, TF_VAR_admin_password) is required when enabled."
    }
    precondition {
      condition     = local.subnet_id != null
      error_message = "foundation_network.subnets.cassandra-mi is required."
    }
  }
}

resource "azurerm_cosmosdb_cassandra_datacenter" "dc1" {
  count                          = local.enabled ? 1 : 0
  name                           = "dc1"
  location                       = azurerm_resource_group.this[0].location
  cassandra_cluster_id           = azurerm_cosmosdb_cassandra_cluster.this[0].id
  delegated_management_subnet_id = local.subnet_id
  node_count                     = var.settings.node_count
  sku_name                       = var.settings.sku_name
  disk_count                     = var.settings.disk_count
  availability_zones_enabled     = false
}
