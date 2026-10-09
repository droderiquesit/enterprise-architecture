output "contract" {
  description = "platform-db-ledger v1 (catalog/contracts/platform-db-ledger.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "azure-confidential-ledger"
    ledger = {
      id                        = azurerm_confidential_ledger.this.id
      name                      = azurerm_confidential_ledger.this.name
      ledger_endpoint           = azurerm_confidential_ledger.this.ledger_endpoint
      identity_service_endpoint = azurerm_confidential_ledger.this.identity_service_endpoint
      ledger_type               = var.settings.ledger_type
      port                      = 443
      # Exception: no private endpoint (README, catalog services networking.private_support=false).
      public_network_access_enabled = true
    }
    auth_mode        = "entra-ledger-role"
    private_endpoint = { enabled = false, id = null, private_ip_address = null }
    databases = {
      for c, d in local.collections : c => {
        name                = c
        boundary            = d.boundary
        owner_identity_name = d.owner
      }
    }
    rbac = [for w in local.writers : {
      identity_name = w
      principal_id  = local.identities[w].principal_id
      role          = "Contributor (ledger role)"
      scope         = azurerm_confidential_ledger.this.id
    }]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Azure Confidential Ledger."
    }
  }
}
