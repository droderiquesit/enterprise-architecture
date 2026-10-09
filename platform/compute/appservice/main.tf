resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  plans = {
    linux             = merge(var.settings.linux_plan, { os_type = "Linux", suffix = "lin" })
    windows           = merge(var.settings.windows_plan, { os_type = "Windows", suffix = "win" })
    windows_container = merge(var.settings.windows_container_plan, { os_type = "WindowsContainer", suffix = "wincont" })
  }
  enabled_plans = { for k, p in local.plans : k => p if p.enabled }
  logicapps     = var.settings.logicapps_plan
}

resource "azurerm_service_plan" "this" {
  for_each = local.enabled_plans

  name                   = "${local.names.app_service_plan}-${each.value.suffix}"
  resource_group_name    = azurerm_resource_group.this.name
  location               = local.location
  os_type                = each.value.os_type
  sku_name               = each.value.sku
  worker_count           = each.value.worker_count
  zone_balancing_enabled = each.value.zone_balancing
  tags                   = local.tags
}

# ---------------------------------------------------------------- Logic Apps Standard
resource "azurerm_service_plan" "logicapps" {
  count = local.logicapps.enabled ? 1 : 0

  name                         = "${local.names.app_service_plan}-logic"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = local.location
  os_type                      = "Windows"
  sku_name                     = local.logicapps.sku
  maximum_elastic_worker_count = local.logicapps.max_elastic_workers
  tags                         = local.tags
}

# Runtime storage for Logic Apps Standard (state, run history, content share). Azure Files does
# not support identity-based access for the content share (WEBSITE_CONTENTAZUREFILECONNECTIONSTRING),
# so shared keys stay enabled on THIS account only; the key is never placed in a contract - the
# deploy-logicapps root reads it at deploy time through its own RBAC.
resource "azurerm_storage_account" "logicapps" {
  count = local.logicapps.enabled ? 1 : 0

  name                     = substr("${local.unique.storage}la", 0, 24)
  resource_group_name      = azurerm_resource_group.this.name
  location                 = local.location
  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = local.logicapps.storage_replication
  min_tls_version          = "TLS1_2"
  #checkov:skip=CKV2_AZURE_40:Logic Apps Standard content share (Azure Files) requires shared-key auth; documented in README.
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for synthetic lab data.
  #checkov:skip=CKV_AZURE_206:LRS is sufficient for a disposable lab runtime store (setting storage_replication).
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  public_network_access           = local.logicapps.storage_private ? "Disabled" : "Enabled"
  https_traffic_only_enabled      = true
  local_user_enabled              = false
  sftp_enabled                    = false
  tags                            = local.tags

  network_rules {
    default_action = local.logicapps.storage_private ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
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

module "logicapps_storage_pe" {
  for_each = local.logicapps.enabled && local.logicapps.storage_private ? toset(["blob", "queue", "table", "file"]) : toset([])
  source   = "../../../foundation/modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-la-${each.key}"
  resource_group_name  = azurerm_resource_group.this.name
  location             = local.location
  subnet_id            = local.subnets["private-endpoints"].id
  target_resource_id   = azurerm_storage_account.logicapps[0].id
  subresource_names    = [each.key]
  private_dns_zone_ids = try([var.foundation_network.private_dns_zones[each.key].id], [])
  tags                 = local.tags
}
