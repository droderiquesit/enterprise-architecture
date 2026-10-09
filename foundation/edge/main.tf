module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "edge"
}

module "tags" {
  source      = "../modules/tags"
  environment = var.environment
  component   = "foundation-edge"
  layer       = "foundation"
  domain      = "edge"
}

locals {
  names    = module.naming.names
  tags     = module.tags.tags
  location = var.environment.location
  s        = var.settings
  subnets  = var.foundation_network.subnets
  hub      = var.foundation_network.topology == "hub-spoke"

  any_enabled = local.s.app_gateway.enabled || local.s.front_door.enabled || local.s.apim.enabled || local.s.firewall.enabled || local.s.bastion.enabled
}

# The resource group exists only when at least one edge component is enabled (zero-cost default).
resource "azurerm_resource_group" "edge" {
  count = local.any_enabled ? 1 : 0

  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  rg_name = local.any_enabled ? azurerm_resource_group.edge[0].name : null
}
