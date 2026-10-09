output "contract" {
  description = "foundation-identity contract v2 (catalog/contracts/foundation-identity.v2.schema.json). DSV references, never values."
  value = {
    resource_group_name = azurerm_resource_group.identity.name
    tenant_id           = var.environment.tenant_id
    identities = {
      for k, v in azurerm_user_assigned_identity.this : k => {
        id           = v.id
        principal_id = v.principal_id
        client_id    = v.client_id
        name         = v.name
        secrets      = local.identities[k].secrets
      }
    }
    # Delinea DSV (ADR-0001 section 14). References are not secrets: dsv://<prefix>/<env>/<name>#value.
    secrets = {
      provider      = "delinea-dsv"
      tenant        = local.dsv_tenant
      tld           = local.dsv_tld
      base_url      = local.dsv_base_url
      base_path     = local.base_path
      auth_provider = var.secrets.auth_provider
      refs          = { for s in local.secret_names : s => "dsv://${local.base_path}/${s}#value" }
    }
  }
}
