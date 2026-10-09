locals {
  component  = "platform-data-analytics"
  workload   = "data-anl"
  identities = var.foundation_identity.identities
  pe_on      = var.settings.private_endpoints_enabled
  pe_subnet  = var.foundation_network.subnets["private-endpoints"].id
  zones      = var.foundation_network.private_dns_zones
  zone       = { for k in ["blob", "dfs", "queue", "table", "search", "kusto"] : k => try(local.zones[k].id, null) }

  adapter_principal_id = try(local.identities["hello-dbadapter"].principal_id, null)
  grant                = local.adapter_principal_id != null

  storage_common = {
    account_kind    = "StorageV2"
    account_tier    = "Standard"
    min_tls_version = "TLS1_2"
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

# ------------------------------------------------------------------ Blob storage (container adapter)
resource "azurerm_storage_account" "blob" {
  #checkov:skip=CKV_AZURE_59:public_network_access = Disabled is set (checkov only inspects the deprecated public_network_access_enabled)
  #checkov:skip=CKV_AZURE_206:lab: LRS by design (synthetic data, cost); replication_type is a setting
  #checkov:skip=CKV_AZURE_36:network_rules bypass None is deliberate: access only via private endpoint
  #checkov:skip=CKV_AZURE_33:storage logging is a diagnostic setting owned by obs-diagnostics (ADR-0001 §3 rule 4)
  #checkov:skip=CKV2_AZURE_1:lab: platform-managed keys + infrastructure encryption; CMK out of scope for synthetic data
  count                             = var.settings.blob.enabled ? 1 : 0
  name                              = substr("${module.naming.unique.storage}b", 0, 24)
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  account_kind                      = local.storage_common.account_kind
  account_tier                      = local.storage_common.account_tier
  account_replication_type          = var.settings.blob.replication_type
  min_tls_version                   = local.storage_common.min_tls_version
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access             = "Disabled"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  local_user_enabled                = false
  infrastructure_encryption_enabled = true
  tags                              = merge(module.tags.tags, { service = "hello-dbadapter" })

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
  }

  blob_properties {
    versioning_enabled = false
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "blob_adapter" {
  #checkov:skip=CKV2_AZURE_21:storage logging is a diagnostic setting owned by obs-diagnostics
  count                 = var.settings.blob.enabled ? 1 : 0
  name                  = "adapter"
  storage_account_id    = azurerm_storage_account.blob[0].id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "blob_adapter" {
  count                = var.settings.blob.enabled && local.grant ? 1 : 0
  scope                = azurerm_storage_container.blob_adapter[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.adapter_principal_id
  principal_type       = "ServicePrincipal"
}

module "pe_blob" {
  count                = var.settings.blob.enabled && local.pe_on ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-blob"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = local.pe_subnet
  target_resource_id   = azurerm_storage_account.blob[0].id
  subresource_names    = ["blob"]
  private_dns_zone_ids = compact([local.zone.blob])
  tags                 = module.tags.tags
}

# ------------------------------------------------------------- ADLS Gen2 (HNS; filesystem adapter)
resource "azurerm_storage_account" "adls" {
  #checkov:skip=CKV_AZURE_59:public_network_access = Disabled is set (checkov only inspects the deprecated public_network_access_enabled)
  #checkov:skip=CKV_AZURE_206:lab: LRS by design (synthetic data, cost); replication_type is a setting
  #checkov:skip=CKV_AZURE_36:network_rules bypass None is deliberate: access only via private endpoint
  #checkov:skip=CKV_AZURE_33:storage logging is a diagnostic setting owned by obs-diagnostics (ADR-0001 §3 rule 4)
  #checkov:skip=CKV2_AZURE_1:lab: platform-managed keys + infrastructure encryption; CMK out of scope for synthetic data
  count                             = var.settings.adls.enabled ? 1 : 0
  name                              = substr("${module.naming.unique.storage}d", 0, 24)
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  account_kind                      = local.storage_common.account_kind
  account_tier                      = local.storage_common.account_tier
  account_replication_type          = var.settings.adls.replication_type
  is_hns_enabled                    = true
  min_tls_version                   = local.storage_common.min_tls_version
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access             = "Disabled"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  local_user_enabled                = false
  sftp_enabled                      = false
  infrastructure_encryption_enabled = true
  tags                              = merge(module.tags.tags, { service = "hello-dbadapter" })

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

# A container on an HNS account is the ADLS Gen2 filesystem; created through ARM (no data-plane access needed).
resource "azurerm_storage_container" "adls_adapter" {
  #checkov:skip=CKV2_AZURE_21:storage logging is a diagnostic setting owned by obs-diagnostics
  count                 = var.settings.adls.enabled ? 1 : 0
  name                  = "adapter"
  storage_account_id    = azurerm_storage_account.adls[0].id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "adls_adapter" {
  count                = var.settings.adls.enabled && local.grant ? 1 : 0
  scope                = azurerm_storage_container.adls_adapter[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.adapter_principal_id
  principal_type       = "ServicePrincipal"
}

module "pe_adls" {
  for_each             = var.settings.adls.enabled && local.pe_on ? toset(["dfs", "blob"]) : toset([])
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-adls-${each.key}"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = local.pe_subnet
  target_resource_id   = azurerm_storage_account.adls[0].id
  subresource_names    = [each.key]
  private_dns_zone_ids = compact([local.zone[each.key]])
  tags                 = module.tags.tags
}

# ------------------------------------------------------------------------ Azure Data Explorer
resource "azurerm_kusto_cluster" "this" {
  #checkov:skip=CKV2_AZURE_11:lab: platform-managed keys; CMK out of scope for synthetic data
  count                         = var.settings.data_explorer.enabled ? 1 : 0
  name                          = replace(substr(module.naming.unique.globally_unique, 0, 22), "-", "")
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  auto_stop_enabled             = var.settings.data_explorer.auto_stop_enabled
  public_network_access_enabled = false
  disk_encryption_enabled       = true
  double_encryption_enabled     = true
  streaming_ingestion_enabled   = false
  purge_enabled                 = false
  tags                          = module.tags.tags

  sku {
    name     = var.settings.data_explorer.sku_name
    capacity = var.settings.data_explorer.capacity
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_kusto_database" "adapter" {
  count               = var.settings.data_explorer.enabled ? 1 : 0
  name                = "adapter"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  cluster_name        = azurerm_kusto_cluster.this[0].name
  hot_cache_period    = var.settings.data_explorer.hot_cache_period
  soft_delete_period  = var.settings.data_explorer.soft_delete_period
}

# ARM-managed control command: boundary table `Records` (catalog: database adapter / table Records).
resource "azurerm_kusto_script" "records_table" {
  count                              = var.settings.data_explorer.enabled ? 1 : 0
  name                               = "create-records-table"
  database_id                        = azurerm_kusto_database.adapter[0].id
  script_content                     = ".create-merge table Records (id: string, payload: dynamic, created_at: datetime)"
  continue_on_errors_enabled         = false
  force_an_update_when_value_changed = "v1"
}

resource "azurerm_kusto_database_principal_assignment" "adapter" {
  for_each            = var.settings.data_explorer.enabled && local.grant ? toset(["User", "Ingestor"]) : toset([])
  name                = "hello-dbadapter-${lower(each.key)}"
  resource_group_name = azurerm_resource_group.this.name
  cluster_name        = azurerm_kusto_cluster.this[0].name
  database_name       = azurerm_kusto_database.adapter[0].name
  tenant_id           = var.environment.tenant_id
  principal_id        = local.identities["hello-dbadapter"].client_id
  principal_type      = "App"
  role                = each.key
}

module "pe_kusto" {
  count                = var.settings.data_explorer.enabled && local.pe_on ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-kusto"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = local.pe_subnet
  target_resource_id   = azurerm_kusto_cluster.this[0].id
  subresource_names    = ["cluster"]
  private_dns_zone_ids = compact([local.zone.kusto, local.zone.blob, local.zone.queue, local.zone.table])
  tags                 = module.tags.tags
}

# ---------------------------------------------------------------------------- Azure AI Search
resource "azurerm_search_service" "this" {
  count                         = var.settings.search.enabled ? 1 : 0
  name                          = module.naming.unique.globally_unique
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = var.settings.search.sku
  replica_count                 = var.settings.search.replica_count
  partition_count               = var.settings.search.partition_count
  public_network_access_enabled = false
  local_authentication_enabled  = false # Entra RBAC only (no admin/query keys)
  tags                          = module.tags.tags

  identity {
    type = "SystemAssigned"
  }
}

# The adapter creates/updates index `adapter-records` and reads/writes documents.
resource "azurerm_role_assignment" "search" {
  for_each             = var.settings.search.enabled && local.grant ? toset(["Search Index Data Contributor", "Search Service Contributor"]) : toset([])
  scope                = azurerm_search_service.this[0].id
  role_definition_name = each.key
  principal_id         = local.adapter_principal_id
  principal_type       = "ServicePrincipal"
}

module "pe_search" {
  count                = var.settings.search.enabled && local.pe_on ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-search"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = local.pe_subnet
  target_resource_id   = azurerm_search_service.this[0].id
  subresource_names    = ["searchService"]
  private_dns_zone_ids = compact([local.zone.search])
  tags                 = module.tags.tags
}

# ------------------------------------------------------------------- Synapse (disabled by default)
resource "azurerm_synapse_workspace" "this" {
  #checkov:skip=CKV_AZURE_240:lab: platform-managed keys; CMK out of scope
  #checkov:skip=CKV2_AZURE_53:auditing is a diagnostic setting owned by obs-diagnostics
  count                                = var.settings.synapse.enabled ? 1 : 0
  name                                 = module.naming.unique.globally_unique
  resource_group_name                  = azurerm_resource_group.this.name
  location                             = azurerm_resource_group.this.location
  storage_data_lake_gen2_filesystem_id = "https://${azurerm_storage_account.adls[0].name}.dfs.core.windows.net/${azurerm_storage_container.adls_adapter[0].name}"
  azuread_authentication_only          = true
  public_network_access_enabled        = false
  managed_virtual_network_enabled      = true
  data_exfiltration_protection_enabled = true
  tags                                 = module.tags.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_synapse_workspace_aad_admin" "this" {
  count                = var.settings.synapse.enabled ? 1 : 0
  synapse_workspace_id = azurerm_synapse_workspace.this[0].id
  login                = var.settings.synapse.entra_admin.login
  object_id            = var.settings.synapse.entra_admin.object_id
  tenant_id            = var.environment.tenant_id
}

resource "azurerm_role_assignment" "synapse_adls" {
  count                = var.settings.synapse.enabled ? 1 : 0
  scope                = azurerm_storage_account.adls[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_synapse_workspace.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# No private DNS zone key exists for Synapse (privatelink.sql.azuresynapse.net) in foundation-network v1,
# so the endpoint is created without a DNS zone group (README: requested contract change).
module "pe_synapse" {
  count               = var.settings.synapse.enabled && local.pe_on ? 1 : 0
  source              = "../../../foundation/modules/private-endpoint"
  name                = "${module.naming.names.private_endpoint}-synapse-sql"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = local.pe_subnet
  target_resource_id  = azurerm_synapse_workspace.this[0].id
  subresource_names   = ["Sql"]
  tags                = module.tags.tags
}
