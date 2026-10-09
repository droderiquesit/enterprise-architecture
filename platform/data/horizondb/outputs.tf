output "contract" {
  description = "platform-db-horizondb v1 (catalog/contracts/platform-db-horizondb.v1.schema.json). No secrets."
  value = {
    enabled             = local.enabled
    status              = local.enabled ? "implemented" : "blocked"
    blocked_reason      = local.enabled ? null : "Azure HorizonDB is in preview; requires preview access in a supported region (README prerequisites)."
    resource_group_name = try(azurerm_resource_group.this[0].name, null)
    engine              = "azure-horizondb"
    api_version         = var.settings.api_version
    cluster = local.enabled ? {
      id                            = azapi_resource.cluster[0].id
      name                          = azapi_resource.cluster[0].name
      fqdn                          = try(azapi_resource.cluster[0].output.properties.fullyQualifiedDomainName, null)
      port                          = 5432
      postgres_version              = var.settings.postgres_version
      vcores                        = var.settings.vcores
      replica_count                 = var.settings.replica_count
      auth_mode                     = "entra-only"
      public_network_access_enabled = true # preview: public access (firewall, no rules by default) + optional private endpoint
      entra_admin = {
        object_id      = var.settings.entra_admin.object_id
        principal_name = var.settings.entra_admin.principal_name
      }
    } : null
    private_endpoint = {
      enabled            = local.pe_enabled
      group_id           = var.settings.private_endpoint_group_id
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    databases = local.enabled ? {
      adapter = {
        name                = "adapter"
        boundary            = "db adapter"
        owner_identity_name = "hello-dbadapter"
        auth_mode           = "entra-managed-identity"
        grants = contains(keys(local.identities), "hello-dbadapter") ? [{
          identity_name = "hello-dbadapter"
          object_id     = local.identities["hello-dbadapter"].principal_id
          privileges    = "owner-of-schema"
          schema        = "adapter"
        }] : []
      }
    } : {}
    dbm = {
      supported = false
      reason    = "HorizonDB is not listed as a supported Datadog Database Monitoring deployment type (preview)."
    }
  }
}
