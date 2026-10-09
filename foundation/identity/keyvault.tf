resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_189:public_network_access_enabled is a setting that defaults to false (private endpoint only); checkov cannot resolve var.settings.
  #checkov:skip=CKV_AZURE_110:purge_protection_enabled is a setting that defaults to true (README documents the teardown implication).
  #checkov:skip=CKV_AZURE_42:soft delete is always on (7-90 days, validated); purge protection defaults to true via settings.
  name                          = module.naming.unique.key_vault
  resource_group_name           = azurerm_resource_group.identity.name
  location                      = local.location
  tenant_id                     = var.environment.tenant_id
  sku_name                      = var.settings.key_vault_sku
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.settings.purge_protection_enabled
  soft_delete_retention_days    = var.settings.soft_delete_retention_days
  public_network_access_enabled = var.settings.public_network_access_enabled
  tags                          = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.settings.allowed_ip_ranges
  }
}

module "key_vault_private_endpoint" {
  source = "../modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-kv"
  resource_group_name  = azurerm_resource_group.identity.name
  location             = local.location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_key_vault.this.id
  subresource_names    = ["vault"]
  private_dns_zone_ids = [var.foundation_network.private_dns_zones["vault"].id]
  tags                 = local.tags
}

# ------------------------------------------------------------------ data-plane RBAC
# Vault-scoped by default: a secret-scoped assignment needs the secret to exist, and secrets are created
# out-of-band after this root is applied. Once scripts/set-secrets.sh has created every secret, set
# settings.secret_scoped_assignments = true to narrow each identity to exactly the secrets it needs.
locals {
  secret_readers = {
    for pair in flatten([
      for id, v in local.identities : [for s in v.secrets : { identity = id, secret = s }]
    ]) : "${pair.identity}/${pair.secret}" => pair
  }
  identities_with_secrets = toset([for id, v in local.identities : id if length(v.secrets) > 0])
}

resource "azurerm_role_assignment" "workload_secrets_user" {
  for_each = var.settings.secret_scoped_assignments ? local.secret_readers : {
    for id in local.identities_with_secrets : id => { identity = id, secret = null }
  }

  scope                = each.value.secret == null ? azurerm_key_vault.this.id : "${azurerm_key_vault.this.id}/secrets/${each.value.secret}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Runtime read of: ${join(", ", local.identities[each.value.identity].secrets)}"
}

resource "azurerm_role_assignment" "pipeline_secrets_user" {
  for_each = toset(var.settings.pipeline_reader_principal_ids)

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
  description          = "Pipeline read of ${join(", ", local.pipeline_secrets)}"
}

resource "azurerm_role_assignment" "secret_officers" {
  for_each = toset(var.settings.secret_officer_principal_ids)

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
  description          = "Out-of-band secret set/rotation (scripts/set-secrets.sh)"
}

# Read access to immutable app packages in the bootstrap `packages` container (no SAS tokens anywhere).
resource "azurerm_role_assignment" "package_readers" {
  for_each = var.settings.packages_container_id == null ? toset([]) : toset([for i in var.settings.package_reader_identities : i if contains(keys(local.identities), i)])

  scope                = var.settings.packages_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.this[each.value].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read app packages (managed-identity download) for ${each.value}"
}
