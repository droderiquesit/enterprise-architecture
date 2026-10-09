resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  identities = var.foundation_identity.identities
  pe         = var.settings.private_endpoints_enabled
  zones      = { for k in ["blob", "queue", "table", "file"] : k => var.foundation_network.private_dns_zones[k].id if contains(keys(var.foundation_network.private_dns_zones), k) }
  pe_subnet  = local.subnets["private-endpoints"].id

  # Functions host storage roles (AzureWebJobsStorage__credential = managedidentity).
  host_roles = {
    blob  = "Storage Blob Data Owner"
    queue = "Storage Queue Data Contributor"
    table = "Storage Table Data Contributor"
  }
  premium = var.settings.premium_plan
  y1      = var.settings.consumption_windows_plan
  dts     = var.settings.durable_task_scheduler
}

# ---------------------------------------------------------------- Flex Consumption
resource "azurerm_service_plan" "flex" {
  for_each = var.settings.flex_apps

  name                = "${local.names.app_service_plan}-flex-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# Host + deployment storage per Flex app: AzureWebJobsStorage (identity-based) and the blob
# container the Flex app deploys from (storage_container_type = "blobContainer",
# storage_authentication_type = "UserAssignedIdentity" on azurerm_function_app_flex_consumption).
module "flex_storage" {
  for_each = var.settings.flex_apps
  source   = "../../modules/compute-runtime-storage"

  name                          = substr("${local.unique.storage}${each.value.storage_suffix}", 0, 24)
  resource_group_name           = azurerm_resource_group.this.name
  location                      = local.location
  replication                   = var.settings.storage_replication
  public_network_access_enabled = !local.pe
  containers                    = ["deploy-${each.key}"]
  private_endpoints             = local.pe ? ["blob", "queue", "table"] : []
  private_endpoint_subnet_id    = local.pe_subnet
  private_endpoint_name_prefix  = local.names.private_endpoint
  private_dns_zone_ids          = local.zones
  tags                          = local.tags
  role_assignments = contains(keys(local.identities), each.value.identity) ? {
    for svc, role in local.host_roles : "${each.value.identity}-${svc}" => { principal_id = local.identities[each.value.identity].principal_id, role = role }
  } : {}
}

# ---------------------------------------------------------------- Durable runtime storage
module "durable_storage" {
  count  = var.settings.durable_storage.enabled ? 1 : 0
  source = "../../modules/compute-runtime-storage"

  name                          = substr("${local.unique.storage}${var.settings.durable_storage.storage_suffix}", 0, 24)
  resource_group_name           = azurerm_resource_group.this.name
  location                      = local.location
  replication                   = var.settings.storage_replication
  public_network_access_enabled = !local.pe
  private_endpoints             = local.pe ? ["blob", "queue", "table"] : []
  private_endpoint_subnet_id    = local.pe_subnet
  private_endpoint_name_prefix  = local.names.private_endpoint
  private_dns_zone_ids          = local.zones
  tags                          = local.tags
  role_assignments = contains(keys(local.identities), var.settings.durable_storage.identity) ? {
    for svc, role in {
      blob  = "Storage Blob Data Contributor"
      queue = "Storage Queue Data Contributor"
      table = "Storage Table Data Contributor"
    } : "${var.settings.durable_storage.identity}-${svc}" => { principal_id = local.identities[var.settings.durable_storage.identity].principal_id, role = role }
  } : {}
}

# ---------------------------------------------------------------- Elastic Premium (Linux)
resource "azurerm_service_plan" "premium" {
  count = local.premium.enabled ? 1 : 0

  name                         = "${local.names.app_service_plan}-ep"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = local.location
  os_type                      = "Linux"
  sku_name                     = local.premium.sku
  maximum_elastic_worker_count = local.premium.max_elastic_workers
  tags                         = local.tags
}

# Runs without Azure Files (WEBSITE_RUN_FROM_PACKAGE blob URL + managed identity), so shared keys stay off.
module "premium_storage" {
  count  = local.premium.enabled ? 1 : 0
  source = "../../modules/compute-runtime-storage"

  name                          = substr("${local.unique.storage}${local.premium.storage_suffix}", 0, 24)
  resource_group_name           = azurerm_resource_group.this.name
  location                      = local.location
  replication                   = var.settings.storage_replication
  public_network_access_enabled = !local.pe
  containers                    = ["packages"]
  private_endpoints             = local.pe ? ["blob", "queue", "table"] : []
  private_endpoint_subnet_id    = local.pe_subnet
  private_endpoint_name_prefix  = local.names.private_endpoint
  private_dns_zone_ids          = local.zones
  tags                          = local.tags
  role_assignments = contains(keys(local.identities), local.premium.identity) ? {
    for svc, role in local.host_roles : "${local.premium.identity}-${svc}" => { principal_id = local.identities[local.premium.identity].principal_id, role = role }
  } : {}
}

# ---------------------------------------------------------------- Windows Consumption (Y1)
resource "azurerm_service_plan" "consumption_windows" {
  count = local.y1.enabled ? 1 : 0

  name                = "${local.names.app_service_plan}-y1"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  os_type             = "Windows"
  sku_name            = "Y1"
  tags                = local.tags
}

module "consumption_storage" {
  count  = local.y1.enabled ? 1 : 0
  source = "../../modules/compute-runtime-storage"

  name                = substr("${local.unique.storage}${local.y1.storage_suffix}", 0, 24)
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  replication         = var.settings.storage_replication
  # Consumption has no VNet integration, so Private Link cannot be used; Entra ID only.
  public_network_access_enabled = true
  containers                    = ["packages"]
  tags                          = local.tags
  role_assignments = contains(keys(local.identities), local.y1.identity) ? {
    for svc, role in local.host_roles : "${local.y1.identity}-${svc}" => { principal_id = local.identities[local.y1.identity].principal_id, role = role }
  } : {}
}

# ---------------------------------------------------------------- Durable Task Scheduler (azapi)
# Provider gap: azurerm 5.9 has no Microsoft.DurableTask resources (catalog/provider-gaps.yaml).
locals {
  dts_allowlist = distinct(concat(
    local.dts.ip_allowlist,
    local.dts.allow_egress_ips ? var.foundation_network.egress.public_ips : [],
  ))
}

resource "azapi_resource" "dts_scheduler" {
  count = local.dts.enabled ? 1 : 0

  type      = "Microsoft.DurableTask/schedulers@2026-02-01"
  name      = "${var.environment.name_prefix}-dts-${var.environment.name}-${module.naming.region_short}"
  parent_id = azurerm_resource_group.this.id
  location  = local.location
  tags      = local.tags

  body = {
    properties = {
      # Entra ID (Durable Task Data Contributor) is always required; the allowlist narrows the
      # network surface to the lab egress IPs. An empty list falls back to "0.0.0.0/0".
      ipAllowlist = length(local.dts_allowlist) > 0 ? local.dts_allowlist : ["0.0.0.0/0"]
      sku = merge(
        { name = local.dts.sku },
        local.dts.capacity == null ? {} : { capacity = local.dts.capacity },
      )
    }
  }
  response_export_values = ["properties.endpoint"]
}

resource "azapi_resource" "dts_task_hub" {
  count = local.dts.enabled ? 1 : 0

  type      = "Microsoft.DurableTask/schedulers/taskHubs@2026-02-01"
  name      = local.dts.task_hub
  parent_id = azapi_resource.dts_scheduler[0].id
  body = {
    properties = {}
  }
}

resource "azurerm_role_assignment" "dts" {
  count = local.dts.enabled && contains(keys(local.identities), local.dts.identity) ? 1 : 0

  scope                = azapi_resource.dts_task_hub[0].id
  role_definition_name = "Durable Task Data Contributor"
  principal_id         = local.identities[local.dts.identity].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Durable Task Scheduler task hub access for ${local.dts.identity}"
}
