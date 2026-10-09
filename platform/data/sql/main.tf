locals {
  component = "platform-db-sql"
  workload  = "data-sql"

  identities = var.foundation_identity.identities
  pe_subnet  = var.foundation_network.subnets["private-endpoints"].id
  sql_zone   = try(var.foundation_network.private_dns_zones["sql"].id, null)

  # Database catalogue: follows catalog/architecture-matrix.yaml `databases:` (owner, boundary).
  # `owner` gets DDL (migrations) + read/write; `readers_writers` get read/write only.
  databases = merge(
    {
      orders = {
        catalog_ref     = "sql-database-provisioned"
        boundary        = "db orders / schema orders"
        schemas         = ["orders"]
        owner           = "hello-orders-api"
        readers_writers = []
        compute_model   = "provisioned"
        dbm_enabled     = true
      }
      fulfillment = {
        catalog_ref     = "sql-database-serverless"
        boundary        = "db fulfillment / schemas fulfillment"
        schemas         = ["fulfillment"]
        owner           = "hello-durable"
        readers_writers = ["hello-jobs"]
        compute_model   = "serverless"
        # DBM's continuous connections would keep the serverless database from auto-pausing.
        dbm_enabled = false
      }
      adapter = {
        catalog_ref     = "sql-database-provisioned"
        boundary        = "db adapter (hello-dbadapter-sql)"
        schemas         = ["adapter"]
        owner           = "hello-dbadapter"
        readers_writers = []
        compute_model   = "provisioned"
        dbm_enabled     = true
      }
    },
    var.settings.elastic_pool.enabled ? {
      adapter_pool = {
        catalog_ref     = "sql-elastic-pool"
        boundary        = "db adapter_pool"
        schemas         = ["adapter"]
        owner           = "hello-dbadapter"
        readers_writers = []
        compute_model   = "elastic-pool"
        dbm_enabled     = true
      }
    } : {},
    var.settings.hyperscale.enabled ? {
      adapter_hs = {
        catalog_ref     = "sql-hyperscale"
        boundary        = "db adapter_hs"
        schemas         = ["adapter"]
        owner           = "hello-dbadapter"
        readers_writers = []
        compute_model   = "hyperscale-serverless"
        dbm_enabled     = var.settings.hyperscale.auto_pause_delay_in_minutes == -1
      }
    } : {},
  )

  # Per-database contained-user grants rendered for scripts/grant-db-users.sql.
  # SID-based creation (WITH SID = <client id>, TYPE = E) avoids a Microsoft Graph lookup, so the
  # server identity does not need the Directory Readers role.
  grants = {
    for db, d in local.databases : db => concat(
      contains(keys(local.identities), d.owner) ? [{
        identity_name = local.identities[d.owner].name
        client_id     = local.identities[d.owner].client_id
        roles         = ["db_datareader", "db_datawriter", "db_ddladmin"]
        schema        = d.schemas[0]
      }] : [],
      [for i in d.readers_writers : {
        identity_name = local.identities[i].name
        client_id     = local.identities[i].client_id
        roles         = ["db_datareader", "db_datawriter"]
        schema        = d.schemas[0]
      } if contains(keys(local.identities), i)],
    )
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

resource "azurerm_mssql_server" "this" {
  #checkov:skip=CKV2_AZURE_2:vulnerability assessment/Defender is a security-platform decision outside this lab component
  #checkov:skip=CKV_AZURE_23:SQL auditing is delivered via diagnostic settings owned by obs-diagnostics (ADR-0001 §10)
  #checkov:skip=CKV_AZURE_24:SQL auditing retention is owned by obs-diagnostics
  name                          = module.naming.unique.globally_unique
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = "12.0"
  minimum_tls_version           = var.settings.minimum_tls_version
  public_network_access_enabled = false
  connection_policy             = "Default"
  tags                          = module.tags.tags

  # Entra-only authentication: no SQL logins exist on the server.
  azuread_administrator {
    login_username              = var.settings.entra_admin.login
    object_id                   = var.settings.entra_admin.object_id
    tenant_id                   = var.environment.tenant_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_mssql_elasticpool" "this" {
  count               = var.settings.elastic_pool.enabled ? 1 : 0
  name                = module.naming.names.sql_elastic_pool
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  server_name         = azurerm_mssql_server.this.name
  max_size_gb         = var.settings.elastic_pool.max_size_gb
  tags                = module.tags.tags

  sku {
    name     = var.settings.elastic_pool.sku_name
    tier     = var.settings.elastic_pool.tier
    capacity = var.settings.elastic_pool.capacity
  }

  per_database_settings {
    min_capacity = var.settings.elastic_pool.db_min_capacity
    max_capacity = var.settings.elastic_pool.db_max_capacity
  }
}

resource "azurerm_mssql_database" "orders" {
  #checkov:skip=CKV_AZURE_224:synthetic data; ledger tables not required
  #checkov:skip=CKV_AZURE_229:lab: single-zone for cost (S0/Basic/serverless)
  name                 = "orders"
  server_id            = azurerm_mssql_server.this.id
  sku_name             = var.settings.orders.sku_name
  max_size_gb          = var.settings.orders.max_size_gb
  storage_account_type = var.settings.backup_storage_redundancy
  zone_redundant       = false
  tags                 = merge(module.tags.tags, { service = "hello-orders-api" })

  short_term_retention_policy {
    retention_days = var.settings.pitr_retention_days
  }
}

resource "azurerm_mssql_database" "fulfillment" {
  #checkov:skip=CKV_AZURE_224:synthetic data; ledger tables not required
  #checkov:skip=CKV_AZURE_229:lab: single-zone for cost (S0/Basic/serverless)
  name                        = "fulfillment"
  server_id                   = azurerm_mssql_server.this.id
  sku_name                    = var.settings.fulfillment.sku_name
  min_capacity                = var.settings.fulfillment.min_capacity
  auto_pause_delay_in_minutes = var.settings.fulfillment.auto_pause_delay_in_minutes
  max_size_gb                 = var.settings.fulfillment.max_size_gb
  storage_account_type        = var.settings.backup_storage_redundancy
  zone_redundant              = false
  tags                        = merge(module.tags.tags, { service = "hello-durable" })

  short_term_retention_policy {
    retention_days = var.settings.pitr_retention_days
  }
}

resource "azurerm_mssql_database" "adapter" {
  #checkov:skip=CKV_AZURE_224:synthetic data; ledger tables not required
  #checkov:skip=CKV_AZURE_229:lab: single-zone for cost (S0/Basic/serverless)
  name                 = "adapter"
  server_id            = azurerm_mssql_server.this.id
  sku_name             = var.settings.adapter.sku_name
  max_size_gb          = var.settings.adapter.max_size_gb
  storage_account_type = var.settings.backup_storage_redundancy
  zone_redundant       = false
  tags                 = merge(module.tags.tags, { service = "hello-dbadapter" })

  short_term_retention_policy {
    retention_days = var.settings.pitr_retention_days
  }
}

resource "azurerm_mssql_database" "adapter_pool" {
  #checkov:skip=CKV_AZURE_224:synthetic data; ledger tables not required
  #checkov:skip=CKV_AZURE_229:lab: single-zone for cost (S0/Basic/serverless)
  count                = var.settings.elastic_pool.enabled ? 1 : 0
  name                 = "adapter_pool"
  server_id            = azurerm_mssql_server.this.id
  elastic_pool_id      = azurerm_mssql_elasticpool.this[0].id
  sku_name             = "ElasticPool"
  storage_account_type = var.settings.backup_storage_redundancy
  tags                 = merge(module.tags.tags, { service = "hello-dbadapter" })

  short_term_retention_policy {
    retention_days = var.settings.pitr_retention_days
  }
}

resource "azurerm_mssql_database" "adapter_hs" {
  #checkov:skip=CKV_AZURE_224:synthetic data; ledger tables not required
  #checkov:skip=CKV_AZURE_229:lab: single-zone for cost (S0/Basic/serverless)
  count                       = var.settings.hyperscale.enabled ? 1 : 0
  name                        = "adapter_hs"
  server_id                   = azurerm_mssql_server.this.id
  sku_name                    = var.settings.hyperscale.sku_name
  min_capacity                = var.settings.hyperscale.min_capacity
  auto_pause_delay_in_minutes = var.settings.hyperscale.auto_pause_delay_in_minutes
  storage_account_type        = var.settings.backup_storage_redundancy
  zone_redundant              = false
  tags                        = merge(module.tags.tags, { service = "hello-dbadapter" })

  short_term_retention_policy {
    retention_days = var.settings.pitr_retention_days
  }
}

module "private_endpoint" {
  count                = var.settings.private_endpoint_enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-sql"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = local.pe_subnet
  target_resource_id   = azurerm_mssql_server.this.id
  subresource_names    = ["sqlServer"]
  private_dns_zone_ids = compact([local.sql_zone])
  tags                 = module.tags.tags
}

check "owner_identities_present" {
  assert {
    condition = alltrue([
      for d in values(local.databases) : contains(keys(local.identities), d.owner)
    ])
    error_message = "One or more database owner identities are missing from foundation_identity.identities; their grants are omitted from the contract."
  }
}
