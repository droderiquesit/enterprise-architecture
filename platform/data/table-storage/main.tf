locals {
  component  = "platform-db-table-storage"
  workload   = "data-table"
  identities = var.foundation_identity.identities

  # catalog/architecture-matrix.yaml databases.table-storage
  tables = {
    notifications  = { owner = "hello-worker", boundary = "table notifications" }
    adapterrecords = { owner = "hello-dbadapter", boundary = "table adapterrecords (hello-dbadapter-table-storage)" }
  }
  grants = { for t, d in local.tables : t => d if contains(keys(local.identities), d.owner) }
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

resource "azurerm_storage_account" "this" {
  name                              = module.naming.unique.storage
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = var.settings.replication_type
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false # Entra ID only
  default_to_oauth_authentication   = true
  public_network_access             = "Disabled"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  local_user_enabled                = false
  sftp_enabled                      = false
  infrastructure_encryption_enabled = true
  tags                              = module.tags.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_table" "this" {
  for_each           = local.tables
  name               = each.key
  storage_account_id = azurerm_storage_account.this.id
}

# Storage Table Data Contributor scoped to each owner's table only.
resource "azurerm_role_assignment" "table_data_contributor" {
  for_each             = local.grants
  scope                = azurerm_storage_table.this[each.key].resource_manager_id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = local.identities[each.value.owner].principal_id
  principal_type       = "ServicePrincipal"
}

module "private_endpoint" {
  count                = var.settings.private_endpoint_enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-table"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_storage_account.this.id
  subresource_names    = ["table"]
  private_dns_zone_ids = compact([try(var.foundation_network.private_dns_zones["table"].id, null)])
  tags                 = module.tags.tags
}
