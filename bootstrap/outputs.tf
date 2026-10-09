output "contract" {
  description = "bootstrap contract v1 (catalog/contracts/bootstrap.v1.schema.json). IDs only; no keys or secrets."
  value = {
    resource_group_name        = azurerm_resource_group.bootstrap.name
    location                   = local.location
    state_storage_account_name = azurerm_storage_account.state.name
    state_storage_account_id   = azurerm_storage_account.state.id
    state_blob_endpoint        = azurerm_storage_account.state.primary_blob_endpoint
    containers                 = { for k, c in azurerm_storage_container.this : k => { name = c.name, id = c.id } }
    state_key_pattern          = "<environment>/<component-id>.tfstate"
    public_network_access      = local.s.public_network_access
    identities = {
      for k, v in azurerm_user_assigned_identity.pipeline : k => {
        id           = v.id
        name         = v.name
        client_id    = v.client_id
        principal_id = v.principal_id
        tenant_id    = v.tenant_id
      }
    }
    federated_credentials = { for k, v in local.federated_credentials : k => { issuer = v.issuer, subject = v.subject } }
    datadog_integration = {
      enabled         = local.dd_enabled
      client_id       = local.dd_enabled ? azuread_application.datadog[0].client_id : null
      tenant_id       = var.environment.tenant_id
      secretless_auth = local.dd_secretless
    }
  }
}

output "backend_config" {
  description = "Values for `terraform init -backend-config=...` in every other root (ADR-0001 §4)."
  value = {
    resource_group_name  = azurerm_resource_group.bootstrap.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = "tfstate"
    use_azuread_auth     = true
  }
}
