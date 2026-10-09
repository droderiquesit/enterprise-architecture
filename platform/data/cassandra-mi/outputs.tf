output "contract" {
  description = "platform-db-cassandra-mi v1 (catalog/contracts/platform-db-cassandra-mi.v1.schema.json). No secrets."
  value = {
    enabled             = local.enabled
    resource_group_name = try(azurerm_resource_group.this[0].name, null)
    engine              = "managed-instance-apache-cassandra"
    cluster = local.enabled ? {
      id                            = azurerm_cosmosdb_cassandra_cluster.this[0].id
      name                          = azurerm_cosmosdb_cassandra_cluster.this[0].name
      version                       = var.settings.cassandra_version
      datacenter                    = "dc1"
      seed_node_ip_addresses        = azurerm_cosmosdb_cassandra_datacenter.dc1[0].seed_node_ip_addresses
      port                          = 9042
      node_count                    = var.settings.node_count
      sku_name                      = var.settings.sku_name
      public_network_access_enabled = false
      admin_login                   = "cassandra"
      admin_password_secret_id      = azurerm_key_vault_secret.admin[0].versionless_id
    } : null
    auth_mode = "cassandra-native"
    databases = local.enabled ? {
      adapter = {
        name                = "adapter"
        boundary            = "keyspace adapter"
        owner_identity_name = "hello-dbadapter"
        login               = "dbadapter"
        password_secret_id  = "${trimsuffix(var.foundation_identity.key_vault_uri, "/")}/secrets/cassandra-mi-dbadapter-password"
        bootstrap_script    = "platform/data/cassandra-mi/scripts/create-keyspace.cql"
      }
    } : {}
    dbm = {
      supported = false
      reason    = "Datadog Database Monitoring does not support Apache Cassandra; use the Agent Cassandra (JMX) integration."
    }
  }
}
