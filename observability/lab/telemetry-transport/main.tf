# Lab root: maps lab contracts to observability/modules/telemetry-transport (the portable module).
module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "obs"
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = "obs-telemetry-transport"
  layer       = "observability"
  service     = "telemetry-transport"
  domain      = "observability"
}

locals {
  kv_uri            = trimsuffix(var.foundation_identity.key_vault_uri, "/")
  api_key_secret_id = lookup(var.foundation_identity.secret_ids, var.settings.api_key_secret_name, "${local.kv_uri}/secrets/${var.settings.api_key_secret_name}")
  shared_key_id     = lookup(var.foundation_identity.secret_ids, var.settings.forward_shared_key_secret_name, "${local.kv_uri}/secrets/${var.settings.forward_shared_key_secret_name}")
  collector         = var.foundation_identity.identities[var.settings.collector_identity_key]
  workload_profile  = coalesce(var.settings.workload_profile_name, try(var.platform_containerapps.workload_profiles[0], null), "Consumption")
  pe_subnet         = try(var.foundation_network.subnets["private-endpoints"].id, null)
  servicebus_dns    = try(var.foundation_network.private_dns_zones["privatelink.servicebus.windows.net"].id, try(var.foundation_network.private_dns_zones["servicebus"].id, null))
  use_pe            = var.settings.event_hub_private_endpoint && local.pe_subnet != null && local.servicebus_dns != null
}

resource "azurerm_resource_group" "this" {
  name     = "${module.naming.names.resource_group}-transport"
  location = var.environment.location
  tags     = module.tags.tags
}

module "transport" {
  source = "../../modules/telemetry-transport"

  name_prefix    = "${var.environment.name_prefix}-obs-${var.environment.name}"
  names          = { eventhub_namespace = "${var.environment.name_prefix}-evhns-obs-${var.environment.name}-${module.naming.suffix}" }
  resource_group = { name = azurerm_resource_group.this.name, id = azurerm_resource_group.this.id }
  location       = var.environment.location
  tags           = module.tags.tags

  datadog = {
    site              = var.settings.datadog_site
    api_key_secret_id = local.api_key_secret_id
    env               = var.environment.name
    extra_tags        = { team = var.environment.team, application = "enterprise-hello", managed_by = "terraform" }
  }
  collector_identity = {
    id           = local.collector.id
    principal_id = local.collector.principal_id
    client_id    = local.collector.client_id
  }
  key_vault = {
    id                 = var.foundation_identity.key_vault_id
    grant_secrets_user = var.settings.grant_key_vault_secrets_user
  }
  event_hub = {
    mode                       = var.settings.event_hub_mode
    capacity                   = var.settings.event_hub_capacity
    listen_secret_key_vault_id = var.settings.event_hub_mode == "create" ? var.foundation_identity.key_vault_id : null
    private_endpoint = local.use_pe ? {
      subnet_id           = local.pe_subnet
      private_dns_zone_id = local.servicebus_dns
    } : null
  }
  container_apps = {
    environment_id        = var.platform_containerapps.environment_id
    workload_profile_name = local.workload_profile
  }
  aggregator = {
    hosting                      = var.settings.aggregator_hosting
    max_replicas                 = var.settings.aggregator_max_replicas
    forward_shared_key_secret_id = local.shared_key_id
  }
  gateway = {
    hosting             = var.settings.gateway_hosting
    distribution        = var.settings.gateway_distribution
    sampling            = var.settings.gateway_sampling
    sampling_percentage = var.settings.gateway_sampling_percentage
    otlp_logs           = var.settings.gateway_otlp_logs
    max_replicas        = var.settings.gateway_sampling == "tail" ? 1 : var.settings.gateway_max_replicas
  }
  sidecar_mode = var.settings.sidecar_mode
}
