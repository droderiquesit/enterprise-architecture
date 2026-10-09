resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# ---------------------------------------------------------------- container registry
locals {
  acr_premium = var.settings.acr_sku == "Premium"
  identities  = var.foundation_identity.identities

  # Only grant identities that exist in the identity contract (profiles may publish a subset).
  acr_pull = { for k in var.settings.acr_pull_identities : k => local.identities[k] if contains(keys(local.identities), k) }
  acr_push = merge(
    { for k in var.settings.acr_push_identities : k => local.identities[k] if contains(keys(local.identities), k) },
    { for p in var.settings.acr_push_principal_ids : "principal-${p}" => { principal_id = p } },
  )

  acr_dns_zone_id = try(var.foundation_network.private_dns_zones["acr"].id, null)
}

resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_233:Zone redundancy is Premium-only; setting acr_zone_redundancy_enabled (enterprise).
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints are Premium-only; enabled automatically when acr_sku = Premium.
  #checkov:skip=CKV_AZURE_164:Content trust (DCT) is deprecated; image signing via Notation is an application pipeline concern.
  #checkov:skip=CKV_AZURE_165:Single-region lab; geo-replication not required.
  #checkov:skip=CKV_AZURE_166:Quarantine requires Premium + an external scanner workflow; not part of the lab.
  #checkov:skip=CKV_AZURE_163:Vulnerability scanning is Microsoft Defender for Containers (subscription plan), not a registry setting.
  name                = local.unique.container_registry
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  sku                 = var.settings.acr_sku
  tags                = local.tags

  # Entra ID only: no admin user, no anonymous pull. Tokens via AcrPull/AcrPush RBAC.
  admin_enabled          = false
  anonymous_pull_enabled = false
  # Public network access can only be disabled on Premium (Private Link).
  public_network_access_enabled = local.acr_premium ? var.settings.acr_public_network_access_enabled : true
  network_rule_bypass_option    = "AzureServices"
  zone_redundancy_enabled       = local.acr_premium ? var.settings.acr_zone_redundancy_enabled : false
  retention_policy_in_days      = local.acr_premium ? var.settings.acr_retention_days : null
  quarantine_policy_enabled     = false
  data_endpoint_enabled         = local.acr_premium
  export_policy_enabled         = local.acr_premium ? var.settings.acr_public_network_access_enabled : true
}

module "acr_private_endpoint" {
  count  = local.acr_premium && var.settings.acr_private_endpoint_enabled ? 1 : 0
  source = "../../foundation/modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-acr"
  resource_group_name  = azurerm_resource_group.this.name
  location             = local.location
  subnet_id            = local.subnets["private-endpoints"].id
  target_resource_id   = azurerm_container_registry.this.id
  subresource_names    = ["registry"]
  private_dns_zone_ids = local.acr_dns_zone_id == null ? [] : [local.acr_dns_zone_id]
  tags                 = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each = local.acr_pull

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AcrPull for ${each.key} (platform-shared)"
}

resource "azurerm_role_assignment" "acr_push" {
  for_each = local.acr_push

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AcrPush for ${each.key} (platform-shared)"
}

# ---------------------------------------------------------------- log analytics
# Platform-feature workspace (not the application log path; see ADR-0001 §10).
resource "azurerm_log_analytics_workspace" "this" {
  name                         = local.names.log_analytics
  resource_group_name          = azurerm_resource_group.this.name
  location                     = local.location
  sku                          = "PerGB2018"
  retention_in_days            = var.settings.log_analytics_retention_days
  daily_quota_gb               = var.settings.log_analytics_daily_quota_gb
  local_authentication_enabled = var.settings.log_analytics_local_auth_enabled
  tags                         = local.tags
}
