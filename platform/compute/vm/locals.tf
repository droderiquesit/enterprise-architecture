# Naming + required tags (ADR-0001 §7).
module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "vm"
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  component   = "platform-vm"
  layer       = "platform"
  domain      = "compute"
  environment = {
    name        = var.environment.name
    location    = var.environment.location
    owner       = var.environment.owner
    team        = var.environment.team
    cost_center = var.environment.cost_center
    expires_on  = var.environment.expires_on
    tags        = var.environment.tags
  }
}

locals {
  tags     = module.tags.tags
  names    = module.naming.names
  unique   = module.naming.unique
  location = var.environment.location
  subnets  = var.foundation_network.subnets
}
