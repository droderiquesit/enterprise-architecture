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

locals {
  # Each platform-db-* contract publishes a `dbm` block (supported, engine, deployment_type, auth_mode,
  # identity_client_id, host, port, resource_id, databases, password_ref | password_secret_name). Passwords are
  # Delinea DSV references: the block's dsv:// password_ref when published, else the ADR-0001 section 14 path
  # dsv://<base_path>/<secret name>#value (legacy password_secret_id: its last segment names the secret).
  dbm_blocks = {
    for k, c in {
      postgresql = var.platform_db_postgresql
      mysql      = var.platform_db_mysql
      sql        = var.platform_db_sql
      sqlmi      = var.platform_db_sqlmi
      sqlvm      = var.platform_db_sqlvm
    } : k => c.dbm if c != null && try(c.dbm.supported, false)
  }
  deployment_type_map = { self_hosted_azure_vm = "virtual_machine" }

  # one DBM instance per database for Azure SQL Database, one per server otherwise
  databases = merge([
    for k, d in local.dbm_blocks : (
      d.engine == "sqlserver" && d.deployment_type == "sql_database" ? {
        for db in try(d.databases, []) : "${k}-${db}" => merge(d, { database = db })
      } : { (k) = merge(d, { database = try(d.databases[0], null) }) }
    )
  ]...)

  dbm_identity = var.foundation_identity.identities[var.settings.identity_key]

  module_databases = { for k, d in local.databases : k => {
    engine                     = d.engine
    deployment_type            = lookup(local.deployment_type_map, d.deployment_type, d.deployment_type)
    host                       = d.host
    port                       = try(d.port, null)
    database                   = d.database
    username                   = d.auth_mode == "entra-managed-identity" ? try(d.identity_name, "obs-dbm") : "datadog"
    auth                       = d.auth_mode == "entra-managed-identity" ? "managed_identity" : "password"
    managed_identity_client_id = d.auth_mode == "entra-managed-identity" ? coalesce(try(d.identity_client_id, null), local.dbm_identity.client_id) : null
    password_ref = d.auth_mode == "entra-managed-identity" ? null : {
      kind = "dsv"
      # platform contracts keep the field name password_secret_id; its value is a dsv:// reference
      name = startswith(try(d.password_ref, ""), "dsv://") ? d.password_ref : startswith(try(d.password_secret_id, ""), "dsv://") ? d.password_secret_id : "dsv://${var.foundation_identity.secrets.base_path}/${coalesce(try(d.password_secret_name, null), try(element(split("/", d.password_secret_id), length(split("/", d.password_secret_id)) - 1), null), "dbm-${k}-password")}#value"
    }
    resource_id = try(d.resource_id, null)
    tags        = { platform_contract = k }
  } }
}

resource "azurerm_resource_group" "this" {
  count    = var.settings.hosting == "aci" && length(local.module_databases) > 0 ? 1 : 0
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

module "dbm" {
  source    = "../../modules/dbm"
  databases = local.module_databases
  hosting   = length(local.module_databases) == 0 ? "none" : var.settings.hosting
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
  aci = var.settings.hosting == "aci" && length(local.module_databases) > 0 ? {
    name                = module.naming.names.container_group
    resource_group_name = azurerm_resource_group.this[0].name
    location            = var.environment.location
    subnet_id           = var.foundation_network.subnets[var.settings.subnet_key].id
    identity_id         = local.dbm_identity.id
    identity_client_id  = local.dbm_identity.client_id
    api_key_ref         = var.obs_telemetry_transport.api_key_ref
    dsv = {
      tenant   = var.obs_telemetry_transport.secrets.tenant
      tld      = var.obs_telemetry_transport.secrets.tld
      base_url = var.obs_telemetry_transport.secrets.base_url
    }
    cpu       = var.settings.cpu
    memory_gb = var.settings.memory_gb
  } : null
}
