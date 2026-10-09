resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  internal = var.settings.ingress_mode == "internal"
  profiles = concat(
    [{ name = "Consumption", workload_profile_type = "Consumption", minimum_count = null, maximum_count = null }],
    var.settings.dedicated_profile.enabled ? [{
      name                  = var.settings.dedicated_profile.name
      workload_profile_type = var.settings.dedicated_profile.type
      minimum_count         = var.settings.dedicated_profile.min_count
      maximum_count         = var.settings.dedicated_profile.max_count
    }] : [],
  )
  dns_vnet_links = merge(
    { spoke = var.foundation_network.spoke_vnet_id },
    var.foundation_network.hub_vnet_id == null ? {} : { hub = var.foundation_network.hub_vnet_id },
    var.settings.extra_dns_vnet_links,
  )
  private_dns = local.internal && var.settings.private_dns_enabled
}

resource "azurerm_container_app_environment" "this" {
  name                               = local.names.container_app_environment
  resource_group_name                = azurerm_resource_group.this.name
  location                           = local.location
  infrastructure_subnet_id           = local.subnets["aca-infra"].id
  infrastructure_resource_group_name = "${local.names.resource_group}-infra"
  internal_load_balancer_enabled     = local.internal
  public_network_access              = local.internal ? "Disabled" : "Enabled"
  zone_redundancy_enabled            = var.settings.zone_redundancy_enabled
  mutual_tls_enabled                 = var.settings.mutual_tls_enabled
  logs_destination                   = var.settings.logs_destination == "none" ? null : var.settings.logs_destination
  log_analytics_workspace_id         = var.settings.logs_destination == "log-analytics" ? var.platform_shared.log_analytics_workspace_id : null
  tags                               = local.tags

  dynamic "workload_profile" {
    for_each = local.profiles
    content {
      name                  = workload_profile.value.name
      workload_profile_type = workload_profile.value.workload_profile_type
      minimum_count         = workload_profile.value.minimum_count
      maximum_count         = workload_profile.value.maximum_count
    }
  }
}

# ---------------------------------------------------------------- internal DNS
# The zone name is the environment's generated default domain, so it cannot be pre-created by
# foundation-network; it is part of this platform (destroyed with the environment).
resource "azurerm_private_dns_zone" "env" {
  count               = local.private_dns ? 1 : 0
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "wildcard" {
  count               = local.private_dns ? 1 : 0
  name                = "*"
  private_dns_zone_id = azurerm_private_dns_zone.env[0].id
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apex" {
  count               = local.private_dns ? 1 : 0
  name                = "@"
  private_dns_zone_id = azurerm_private_dns_zone.env[0].id
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "env" {
  for_each = local.private_dns ? local.dns_vnet_links : {}

  name                 = "link-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.env[0].id
  virtual_network_id   = each.value
  registration_enabled = false
  tags                 = local.tags
}
