locals {
  component   = "platform-db-documentdb"
  workload    = "data-docdb"
  identities  = var.foundation_identity.identities
  admin_login = "ehdocdbadmin"

  # catalog/architecture-matrix.yaml databases.documentdb
  owner              = "hello-dbadapter"
  boundary           = "db adapter / collection records"
  owner_principal_id = try(local.identities[local.owner].principal_id, null)
  secret_tags        = { for k, v in module.tags.tags : k => v if contains(["env", "application", "component", "layer", "owner", "team", "managed_by", "expires_on", "data_classification", "repository"], k) }
}

# Native authentication must be enabled at creation, so a built-in admin exists. Its password is kept
# in state (no write-only argument on azurerm_mongo_cluster) and copied write-only to Key Vault.
resource "random_password" "admin" {
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*-_+=?"
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

# Azure DocumentDB (formerly Azure Cosmos DB for MongoDB vCore): Microsoft.DocumentDB/mongoClusters.
resource "azurerm_mongo_cluster" "this" {
  name                   = module.naming.unique.globally_unique
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  administrator_username = local.admin_login
  administrator_password = random_password.admin.result
  compute_tier           = var.settings.compute_tier
  storage_size_in_gb     = var.settings.storage_size_in_gb
  shard_count            = 1
  high_availability_mode = "Disabled" # M10-M25 do not support in-region HA
  version                = var.settings.server_version
  public_network_access  = "Disabled"
  authentication_methods = ["NativeAuth", "MicrosoftEntraID"]
  tags                   = module.tags.tags
}

# Entra principal for hello-dbadapter. azurerm only accepts the built-in `root` role on `admin`
# (least-privilege gap recorded in README).
resource "azurerm_mongo_cluster_user" "dbadapter" {
  count                  = local.owner_principal_id == null ? 0 : 1
  mongo_cluster_id       = azurerm_mongo_cluster.this.id
  object_id              = local.owner_principal_id
  identity_provider_type = "MicrosoftEntraID"
  principal_type         = "servicePrincipal"

  role {
    database = "admin"
    name     = "root"
  }
}

module "private_endpoint" {
  count                = var.settings.private_endpoint_enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-docdb"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_mongo_cluster.this.id
  subresource_names    = ["MongoCluster"]
  private_dns_zone_ids = compact([try(var.foundation_network.private_dns_zones["documentdb"].id, null)])
  tags                 = module.tags.tags
}

resource "azurerm_key_vault_secret" "admin" {
  name             = var.settings.admin_secret_name
  key_vault_id     = var.foundation_identity.key_vault_id
  value_wo         = random_password.admin.result
  value_wo_version = var.settings.secret_version
  content_type     = "password"
  expiration_date  = "${var.environment.expires_on}T00:00:00Z"
  tags             = local.secret_tags
}
