# Private DNS zones for every Private Link service used in the catalogue. Zone names follow
# https://learn.microsoft.com/azure/private-link/private-endpoint-dns (verified 2026-10-09).
# Contract key (short key) => zone name. Consumers look zones up by short key, never by name.
#
# Not included on purpose:
#   - Azure confidential ledger: no Private Link resource / DNS zone is listed in the Learn table above
#     (checked 2026-10-09) -> platform-db-ledger stays on its public endpoint (AAD/cert auth) and records that.
#   - SQL Managed Instance: the VNet-local endpoint needs no zone; MI private endpoints would need
#     privatelink.<dnsPrefix>.database.windows.net, which is instance specific (platform-db-sqlmi owns it if used).
#   - AMPLS zones are opt-in (settings.ampls_zones) because they redirect *all* Azure Monitor endpoints.
locals {
  region = var.environment.location

  default_private_dns_zones = {
    blob             = "privatelink.blob.core.windows.net"
    file             = "privatelink.file.core.windows.net"
    queue            = "privatelink.queue.core.windows.net"
    table            = "privatelink.table.core.windows.net"
    dfs              = "privatelink.dfs.core.windows.net"
    vault            = "privatelink.vaultcore.azure.net"
    sql              = "privatelink.database.windows.net"
    postgres         = "privatelink.postgres.database.azure.com"
    mysql            = "privatelink.mysql.database.azure.com"
    cosmos_sql       = "privatelink.documents.azure.com"
    cosmos_mongo     = "privatelink.mongo.cosmos.azure.com"
    cosmos_cassandra = "privatelink.cassandra.cosmos.azure.com"
    cosmos_gremlin   = "privatelink.gremlin.cosmos.azure.com"
    cosmos_table     = "privatelink.table.cosmos.azure.com"
    mongocluster     = "privatelink.mongocluster.cosmos.azure.com" # Azure DocumentDB (Cosmos DB for MongoDB vCore)
    redis            = "privatelink.redis.azure.net"               # Azure Managed Redis (Microsoft.Cache/redisEnterprise)
    servicebus       = "privatelink.servicebus.windows.net"        # Service Bus + Event Hubs
    acr              = "privatelink.azurecr.io"
    webapps          = "privatelink.azurewebsites.net" # App Service / Functions (scm records live in the same zone)
    aca              = "privatelink.${local.region}.azurecontainerapps.io"
    aks              = "privatelink.${local.region}.azmk8s.io" # private AKS API server
    search           = "privatelink.search.windows.net"
    kusto            = "privatelink.${local.region}.kusto.windows.net"
    batch            = "privatelink.batch.azure.com"
    apim             = "privatelink.azure-api.net"
    # Flexible Server VNet injection needs a zone ending in <engine>.database.azure.com; a dedicated
    # non-privatelink zone avoids clashing with private-endpoint records in the privatelink zone.
    postgres_vnet = "${var.environment.name_prefix}${var.environment.name}.private.postgres.database.azure.com"
    mysql_vnet    = "${var.environment.name_prefix}${var.environment.name}.private.mysql.database.azure.com"
  }

  ampls_private_dns_zones = var.settings.ampls_zones ? {
    monitor  = "privatelink.monitor.azure.com"
    oms      = "privatelink.oms.opinsights.azure.com"
    ods      = "privatelink.ods.opinsights.azure.com"
    agentsvc = "privatelink.agentsvc.azure-automation.net"
  } : {}

  private_dns_zones = {
    for k, v in merge(local.default_private_dns_zones, local.ampls_private_dns_zones, var.settings.private_dns_zones_extra) : k => v
    if !contains(var.settings.private_dns_zones_exclude, k)
  }

  linked_vnets = merge(
    { spoke = azurerm_virtual_network.spoke.id },
    local.hub ? { hub = azurerm_virtual_network.hub[0].id } : {}
  )

  zone_links = merge([
    for zk, _ in local.private_dns_zones : {
      for vk, vid in local.linked_vnets : "${zk}/${vk}" => { zone = zk, vnet = vk, vnet_id = vid }
    }
  ]...)

  internal_dns_zone = coalesce(var.settings.internal_dns_zone, "${var.environment.name}.${var.environment.name_prefix}.lab.internal")
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.zone_links

  name                 = "${each.value.zone}-${each.value.vnet}"
  private_dns_zone_id  = azurerm_private_dns_zone.this[each.value.zone].id
  virtual_network_id   = each.value.vnet_id
  registration_enabled = false
  tags                 = local.tags
}

# Lab-internal zone (service names for VMs, internal load balancers, the DBM agent, etc.).
resource "azurerm_private_dns_zone" "internal" {
  name                = local.internal_dns_zone
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  for_each = local.linked_vnets

  name                 = "internal-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.internal.id
  virtual_network_id   = each.value
  registration_enabled = each.key == "spoke" ? var.settings.internal_dns_zone_registration : false
  tags                 = local.tags
}
