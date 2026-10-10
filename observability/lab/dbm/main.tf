module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "obs-dbm"
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = "obs-dbm"
  layer       = "observability"
  service     = "datadog-dbm"
  domain      = "observability"
}

# platform-db-* contracts -> DBM instances (shared with obs-kubernetes, which runs them as cluster checks)
module "dbm_contracts" {
  source = "../../modules/dbm/contracts"
  contracts = {
    postgresql = var.platform_db_postgresql
    mysql      = var.platform_db_mysql
    sql        = var.platform_db_sql
    sqlmi      = var.platform_db_sqlmi
    sqlvm      = var.platform_db_sqlvm
  }
  base_path          = var.foundation_identity.secrets.base_path
  identity_client_id = local.dbm_identity.client_id
}

locals {
  dbm_identity     = var.foundation_identity.identities[var.settings.identity_key]
  module_databases = module.dbm_contracts.databases
  # settings.hosting = auto: a cluster (platform-aks contract) runs the DBM checks as cluster checks of its Cluster
  # Agent (obs-kubernetes renders them from the same contracts); the ACI Agent only when there is no cluster
  hosting = var.settings.hosting == "auto" ? (var.platform_aks != null ? "cluster_checks" : "aci") : var.settings.hosting
  aci_on  = local.hosting == "aci" && length(local.module_databases) > 0
}

resource "azurerm_resource_group" "this" {
  count    = local.aci_on ? 1 : 0
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

module "dbm" {
  source    = "../../modules/dbm"
  databases = local.module_databases
  hosting   = length(local.module_databases) == 0 ? "none" : local.hosting
  datadog   = { site = var.obs_telemetry_transport.datadog_site, env = var.environment.name }
  tags      = module.tags.tags
  # package 3.0.0: canonical tag policy values of the lab databases (modules/tagging; service = database key)
  identity = {
    team        = var.environment.team
    owner       = var.environment.owner
    application = "enterprise-hello"
    domain      = "data"
    tier        = "infrastructure"
    region      = var.environment.location
    managed_by  = "terraform"
  }
  aci = local.aci_on ? {
    name                = module.naming.names.container_group
    resource_group_name = azurerm_resource_group.this[0].name
    location            = var.environment.location
    subnet_id           = var.foundation_network.subnets[var.settings.subnet_key].id
    identity_id         = local.dbm_identity.id
    identity_client_id  = local.dbm_identity.client_id
    api_key_ref         = var.obs_telemetry_transport.api_key_ref
    # registry artifact img-dsv-fetch (digest-pinned): init container copying the static binary for the Agent
    fetch_image = try(coalesce(try(var.artifacts["img-dsv-fetch"].image, null), var.obs_telemetry_transport.secrets.fetch_image), null)
    dsv = {
      tenant   = var.obs_telemetry_transport.secrets.tenant
      tld      = var.obs_telemetry_transport.secrets.tld
      base_url = var.obs_telemetry_transport.secrets.base_url
    }
    cpu       = var.settings.cpu
    memory_gb = var.settings.memory_gb
  } : null
}
