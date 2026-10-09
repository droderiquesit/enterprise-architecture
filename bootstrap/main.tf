module "naming" {
  source          = "../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "tfstate"
}

module "tags" {
  source      = "../foundation/modules/tags"
  environment = var.environment
  component   = "bootstrap"
  layer       = "bootstrap"
  domain      = "delivery"
}

locals {
  names        = module.naming.names
  tags         = module.tags.tags
  location     = var.environment.location
  subscription = "/subscriptions/${var.environment.subscription_id}"
  s            = var.settings

  # ADR-0001 §4 containers.
  containers = {
    tfstate     = "Terraform state, key <env>/<component>.tfstate (blob lease locking)"
    contracts   = "published output contracts contracts/<env>/<contract>/v<major>.json"
    plans       = "saved plan files (sensitive: may contain secrets from providers)"
    deployments = "component deployment records"
    packages    = "immutable zip/static packages (by sha256)"
    evidence    = "deployment / verification evidence"
  }
}

resource "azurerm_resource_group" "bootstrap" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# ------------------------------------------------------------------ state storage account
resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys + infrastructure (double) encryption; a CMK would need a Key Vault that itself depends on this state.
  #checkov:skip=CKV_AZURE_33:Queue service is unused; state lives in blob containers only.
  #checkov:skip=CKV2_AZURE_33:Private endpoint is phase 2 (settings.private_endpoint) once the VNet exists; phase 1 uses the IP/subnet firewall.
  #checkov:skip=CKV_AZURE_59:Public network access is required in phase 1 (Microsoft-hosted agents) with default-deny firewall; set public_network_access = Disabled in phase 2.
  #checkov:skip=CKV_AZURE_206:Replication is a setting defaulting to ZRS (checkov cannot resolve local.s.replication_type).
  #checkov:skip=CKV2_AZURE_41:Shared keys (and therefore SAS) are disabled; a SAS expiration policy would be dead configuration.
  name                              = module.naming.unique.storage
  resource_group_name               = azurerm_resource_group.bootstrap.name
  location                          = local.location
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = local.s.replication_type
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true
  local_user_enabled                = false
  sftp_enabled                      = false
  public_network_access             = local.s.public_network_access
  tags                              = local.tags

  blob_properties {
    versioning_enabled            = true
    change_feed_enabled           = true
    change_feed_retention_in_days = local.s.change_feed_retention_days
    last_access_time_enabled      = false

    delete_retention_policy {
      days = local.s.blob_soft_delete_days
    }
    container_delete_retention_policy {
      days = local.s.container_soft_delete_days
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices", "Logging", "Metrics"]
    ip_rules                   = local.s.operator_ip_ranges
    virtual_network_subnet_ids = local.s.agent_subnet_ids
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "this" {
  #checkov:skip=CKV2_AZURE_21:Diagnostic settings (StorageRead logs) are owned by observability (obs-diagnostics) per ADR-0001 §3 rule 4.
  for_each = local.containers

  name                  = each.key
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
  metadata              = { purpose = replace(lower(each.value), "/[^a-z0-9]+/", "_") }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_management_lock" "state" {
  count = local.s.lock_enabled ? 1 : 0

  name       = "do-not-delete-terraform-state"
  scope      = azurerm_storage_account.state.id
  lock_level = "CanNotDelete"
  notes      = "Terraform state for every lab component. Remove only via the break-glass procedure in bootstrap/README.md."
}

# Phase 2: private endpoint once foundation-network exists (values copied from its contract).
module "state_private_endpoint" {
  count  = local.s.private_endpoint == null ? 0 : 1
  source = "../foundation/modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-state-blob"
  resource_group_name  = azurerm_resource_group.bootstrap.name
  location             = local.location
  subnet_id            = local.s.private_endpoint.subnet_id
  target_resource_id   = azurerm_storage_account.state.id
  subresource_names    = ["blob"]
  private_dns_zone_ids = [local.s.private_endpoint.private_dns_zone_id]
  tags                 = local.tags
}
