locals {
  component  = "platform-db-sqlmi"
  workload   = "data-sqlmi"
  enabled    = var.settings.enabled
  identities = var.foundation_identity.identities
  subnet_id  = try(var.foundation_network.subnets["sqlmi"].id, null)
  mi_id      = local.enabled ? (var.settings.free_offer ? azapi_resource.free[0].id : azurerm_mssql_managed_instance.this[0].id) : null
  mi_name    = module.naming.names.sql_managed_instance
  mi_fqdn    = local.enabled ? (var.settings.free_offer ? azapi_resource.free[0].output.properties.fullyQualifiedDomainName : azurerm_mssql_managed_instance.this[0].fqdn) : null

  # catalog/architecture-matrix.yaml databases.sql-managed-instance
  databases = {
    adapter = { owner = "hello-dbadapter", boundary = "db adapter", schema = "adapter" }
  }
  grants = {
    for db, d in local.databases : db => [{
      identity_name = d.owner
      client_id     = local.identities[d.owner].client_id
      roles         = ["db_datareader", "db_datawriter", "db_ddladmin"]
      schema        = d.schema
    }] if contains(keys(local.identities), d.owner)
  }
  weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
}

module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = local.workload
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = local.component
  layer       = "platform"
  domain      = "data"
  tier        = "database"
}

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

# SQL MI lives in the delegated `sqlmi` subnet (Microsoft.Sql/managedInstances), which foundation-network
# must associate with an NSG and a route table (service-aided subnet configuration adds the required rules).
resource "azurerm_mssql_managed_instance" "this" {
  count                        = local.enabled && !var.settings.free_offer ? 1 : 0
  name                         = local.mi_name
  resource_group_name          = azurerm_resource_group.this[0].name
  location                     = azurerm_resource_group.this[0].location
  subnet_id                    = local.subnet_id
  sku_name                     = var.settings.sku_name
  vcores                       = var.settings.vcores
  storage_size_in_gb           = var.settings.storage_size_in_gb
  storage_account_type         = "LRS"
  license_type                 = var.settings.license_type
  minimum_tls_version          = var.settings.minimum_tls_version
  public_data_endpoint_enabled = false
  zone_redundant_enabled       = false
  timezone_id                  = "UTC"
  tags                         = module.tags.tags

  azure_active_directory_administrator {
    login_username                      = var.settings.entra_admin.login
    object_id                           = var.settings.entra_admin.object_id
    principal_type                      = var.settings.entra_admin.principal_type
    tenant_id                           = var.environment.tenant_id
    azuread_authentication_only_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }

  timeouts {
    create = "8h"
    update = "8h"
    delete = "8h"
  }

  lifecycle {
    precondition {
      condition     = local.subnet_id != null
      error_message = "foundation_network.subnets.sqlmi (delegated to Microsoft.Sql/managedInstances) is required."
    }
  }
}

# AzAPI gap: azurerm_mssql_managed_instance has no pricingModel argument, so the free offer
# (pricingModel = Freemium) is created through ARM directly.
resource "azapi_resource" "free" {
  count     = local.enabled && var.settings.free_offer ? 1 : 0
  type      = "Microsoft.Sql/managedInstances@2025-01-01"
  name      = local.mi_name
  parent_id = azurerm_resource_group.this[0].id
  location  = azurerm_resource_group.this[0].location
  tags      = module.tags.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name     = var.settings.sku_name
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = var.settings.vcores
    }
    properties = {
      pricingModel                     = "Freemium"
      subnetId                         = local.subnet_id
      vCores                           = var.settings.vcores
      storageSizeInGB                  = var.settings.storage_size_in_gb
      licenseType                      = var.settings.license_type
      minimalTlsVersion                = var.settings.minimum_tls_version
      publicDataEndpointEnabled        = false
      zoneRedundant                    = false
      requestedBackupStorageRedundancy = "Local"
      timezoneId                       = "UTC"
      administrators = {
        administratorType         = "ActiveDirectory"
        azureADOnlyAuthentication = true
        login                     = var.settings.entra_admin.login
        sid                       = var.settings.entra_admin.object_id
        principalType             = var.settings.entra_admin.principal_type
        tenantId                  = var.environment.tenant_id
      }
    }
  }

  response_export_values = ["properties.fullyQualifiedDomainName"]

  timeouts {
    create = "8h"
    update = "8h"
    delete = "8h"
  }
}

resource "azurerm_mssql_managed_database" "this" {
  for_each                  = local.enabled ? local.databases : {}
  name                      = each.key
  managed_instance_id       = local.mi_id
  short_term_retention_days = var.settings.pitr_retention_days
  tags                      = merge(module.tags.tags, { service = each.value.owner })
}

resource "azurerm_mssql_managed_instance_start_stop_schedule" "this" {
  count               = local.enabled && var.settings.stop_schedule_enabled ? 1 : 0
  managed_instance_id = local.mi_id
  timezone_id         = var.settings.schedule_timezone
  description         = "Lab cost control: run on weekdays only."

  dynamic "schedule" {
    for_each = local.weekdays
    content {
      start_day  = schedule.value
      start_time = var.settings.start_time
      stop_day   = schedule.value
      stop_time  = var.settings.stop_time
    }
  }
}
