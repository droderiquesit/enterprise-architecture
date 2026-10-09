locals {
  component   = "platform-db-cassandra-mi"
  workload    = "data-cassmi"
  enabled     = var.settings.enabled
  subnet_id   = try(var.foundation_network.subnets["cassandra-mi"].id, null)
  role_scope  = var.settings.network_contributor_scope == "vnet" ? var.foundation_network.spoke_vnet_id : local.subnet_id
  secret_tags = { for k, v in module.tags.tags : k => v if contains(["env", "application", "component", "layer", "owner", "team", "managed_by", "expires_on", "data_classification", "repository"], k) }
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

# Required by the cluster resource (no write-only variant): kept in state and copied write-only to Key Vault.
resource "random_password" "admin" {
  count            = local.enabled ? 1 : 0
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*-_+=?"
}

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
  default_admin_password         = random_password.admin[0].result
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

resource "azurerm_key_vault_secret" "admin" {
  count            = local.enabled ? 1 : 0
  name             = var.settings.admin_secret_name
  key_vault_id     = var.foundation_identity.key_vault_id
  value_wo         = random_password.admin[0].result
  value_wo_version = var.settings.secret_version
  content_type     = "password"
  expiration_date  = "${var.environment.expires_on}T00:00:00Z"
  tags             = local.secret_tags
}
