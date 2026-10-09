output "contract" {
  description = "platform-db-redis v1 (catalog/contracts/platform-db-redis.v1.schema.json). No secrets."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    engine              = "azure-managed-redis"
    cache = {
      id                            = azurerm_managed_redis.this.id
      name                          = azurerm_managed_redis.this.name
      hostname                      = azurerm_managed_redis.this.hostname
      port                          = 10000
      sku_name                      = var.settings.sku_name
      tls                           = true
      public_network_access_enabled = false
      access_keys_enabled           = false
      eviction_policy               = var.settings.eviction_policy
      clustering_policy             = var.settings.clustering_policy
      persistence                   = "none"
    }
    auth_mode = "entra-access-policy"
    private_endpoint = {
      enabled            = var.settings.private_endpoint_enabled
      group_id           = "redisEnterprise"
      id                 = try(module.private_endpoint[0].id, null)
      private_ip_address = try(module.private_endpoint[0].private_ip_address, null)
    }
    # Logical boundaries are key prefixes (one Redis database per instance).
    databases = {
      for k, v in local.clients : trimsuffix(v.key_prefix, ":") => {
        name                = "0"
        key_prefix          = v.key_prefix
        boundary            = "key prefix ${v.key_prefix}"
        owner_identity_name = k
        durable             = false
      }
    }
    rbac = [for k, oid in local.access : {
      identity_name = k
      principal_id  = oid
      role          = "default access policy (Data Owner)"
      scope         = azurerm_managed_redis.this.id
    }]
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not cover Redis; use the Azure integration and the Agent Redis check."
    }
  }
}
