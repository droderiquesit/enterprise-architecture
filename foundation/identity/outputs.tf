output "contract" {
  description = "foundation-identity contract v1 (catalog/contracts/foundation-identity.v1.schema.json). Secret IDs are versionless references, never values."
  value = {
    resource_group_name = azurerm_resource_group.identity.name
    key_vault_id        = azurerm_key_vault.this.id
    key_vault_uri       = azurerm_key_vault.this.vault_uri
    key_vault_name      = azurerm_key_vault.this.name
    identities = {
      for k, v in azurerm_user_assigned_identity.this : k => {
        id           = v.id
        principal_id = v.principal_id
        client_id    = v.client_id
        name         = v.name
        tenant_id    = v.tenant_id
        secrets      = local.identities[k].secrets
      }
    }
    # Versionless secret IDs: "<vault_uri>secrets/<name>" (vault_uri ends with "/"). Consumers resolve the
    # latest version at runtime (Key Vault references, CSI driver, ACA secret refs).
    secret_ids = { for s in local.secret_names : s => "${azurerm_key_vault.this.vault_uri}secrets/${s}" }
  }
}
