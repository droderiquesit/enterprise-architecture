locals {
  component  = "platform-db-horizondb"
  workload   = "data-hzdb"
  enabled    = var.settings.enabled
  identities = var.foundation_identity.identities
  pe_enabled = local.enabled && var.settings.private_endpoint_group_id != null
  # HorizonDB regions during preview (Microsoft Learn, "What is Azure HorizonDB"): checked as a precondition.
  preview_regions = ["canadacentral", "centralus", "eastus", "westus2", "westus3", "germanywestcentral", "swedencentral", "australiaeast", "koreacentral"]
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

# administratorLogin/Password are mandatory at create time even with password auth disabled; the
# password is ephemeral and sent write-only (sensitive_body), so it never reaches state.
ephemeral "random_password" "admin" {
  count       = local.enabled ? 1 : 0
  length      = 32
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
}

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

# AzAPI gap: azurerm has no HorizonDB resources. The preview API version used here is newer than the
# schemas embedded in azapi 2.13 (which know 2026-01-20-preview without authConfig), so embedded schema
# validation is disabled for this resource only.
resource "azapi_resource" "cluster" {
  count                     = local.enabled ? 1 : 0
  type                      = "Microsoft.HorizonDb/clusters@${var.settings.api_version}"
  name                      = module.naming.names.horizondb
  parent_id                 = azurerm_resource_group.this[0].id
  location                  = azurerm_resource_group.this[0].location
  tags                      = module.tags.tags
  schema_validation_enabled = false

  body = {
    properties = {
      createMode          = "Create"
      version             = var.settings.postgres_version
      administratorLogin  = "ehhzadmin"
      vCores              = var.settings.vcores
      replicaCount        = var.settings.replica_count
      zonePlacementPolicy = var.settings.zone_placement_policy
      authConfig = {
        entraIdAuth  = "Enabled"
        passwordAuth = "Disabled"
        tenantId     = var.environment.tenant_id
      }
    }
  }

  sensitive_body = {
    properties = {
      administratorLoginPassword = ephemeral.random_password.admin[0].result
    }
  }
  sensitive_body_version = {
    "properties.administratorLoginPassword" = tostring(var.settings.admin_password_version)
  }

  response_export_values = ["properties.fullyQualifiedDomainName"]

  lifecycle {
    precondition {
      condition     = var.settings.preview_access_confirmed
      error_message = "HorizonDB is in preview: set settings.preview_access_confirmed = true only after the subscription has preview access (README prerequisites)."
    }
    precondition {
      condition     = contains(local.preview_regions, var.environment.location)
      error_message = "HorizonDB preview is not offered in this region (README lists the documented preview regions)."
    }
  }
}

resource "azapi_resource" "entra_admin" {
  count                     = local.enabled ? 1 : 0
  type                      = "Microsoft.HorizonDb/clusters/administrators@${var.settings.api_version}"
  name                      = var.settings.entra_admin.object_id
  parent_id                 = azapi_resource.cluster[0].id
  schema_validation_enabled = false
  body = {
    properties = {
      principalName = var.settings.entra_admin.principal_name
      principalType = var.settings.entra_admin.principal_type
      tenantId      = var.environment.tenant_id
    }
  }
}

module "private_endpoint" {
  count                = local.pe_enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = "${module.naming.names.private_endpoint}-hzdb"
  resource_group_name  = azurerm_resource_group.this[0].name
  location             = azurerm_resource_group.this[0].location
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azapi_resource.cluster[0].id
  subresource_names    = [var.settings.private_endpoint_group_id]
  private_dns_zone_ids = []
  tags                 = module.tags.tags
}
