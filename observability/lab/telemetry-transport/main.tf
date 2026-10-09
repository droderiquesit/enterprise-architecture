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
  # Delinea DSV references from foundation-identity v2 (secrets.refs); the derived form is the ADR-0001 section 14
  # path layout /<name_prefix>/<env>/<secret-name>#value for names foundation does not list.
  dsv              = var.foundation_identity.secrets
  ref              = { for n in [var.settings.api_key_secret_name, var.settings.forward_shared_key_secret_name, var.settings.eventhub_listen_secret_name] : n => lookup(local.dsv.refs, n, "dsv://${local.dsv.base_path}/${n}#value") }
  api_key_ref      = local.ref[var.settings.api_key_secret_name]
  fetch_image      = try(var.artifacts[var.settings.fetch_artifact].image, null)
  collector        = var.foundation_identity.identities[var.settings.collector_identity_key]
  workload_profile = coalesce(var.settings.workload_profile_name, try(var.platform_containerapps.workload_profiles[0], null), "Consumption")
  pe_subnet        = try(var.foundation_network.subnets["private-endpoints"].id, null)
  servicebus_dns   = try(var.foundation_network.private_dns_zones["privatelink.servicebus.windows.net"].id, try(var.foundation_network.private_dns_zones["servicebus"].id, null))
  use_pe           = var.settings.event_hub_private_endpoint && local.pe_subnet != null && local.servicebus_dns != null
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
    site        = var.settings.datadog_site
    api_key_ref = local.api_key_ref
    env         = var.environment.name
    extra_tags  = { team = var.environment.team, application = "enterprise-hello", managed_by = "terraform" }
  }
  collector_identity = {
    id           = local.collector.id
    principal_id = local.collector.principal_id
    client_id    = local.collector.client_id
  }
  secrets = {
    tenant      = local.dsv.tenant
    tld         = local.dsv.tld
    base_url    = local.dsv.base_url
    auth        = "azure"
    fetch_image = local.fetch_image
  }
  event_hub = {
    mode              = var.settings.event_hub_mode
    capacity          = var.settings.event_hub_capacity
    activity_logs_hub = var.settings.event_hub_activity_logs_hub
    # create: publish.py stores generated_secrets["eventhub-fluentbit-listen"] at this DSV path after apply
    listen_connection_string_ref = var.settings.event_hub_mode == "none" ? null : local.ref[var.settings.eventhub_listen_secret_name]
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
    hosting                = var.settings.aggregator_hosting
    max_replicas           = var.settings.aggregator_max_replicas
    forward_shared_key_ref = local.ref[var.settings.forward_shared_key_secret_name]
  }
  gateway = {
    hosting             = var.settings.gateway_hosting
    distribution        = var.settings.gateway_distribution
    sampling            = var.settings.gateway_sampling
    sampling_percentage = var.settings.gateway_sampling_percentage
    otlp_logs           = var.settings.gateway_otlp_logs
    max_replicas        = var.settings.gateway_sampling == "tail" ? 1 : var.settings.gateway_max_replicas
  }
  sidecar_mode      = var.settings.sidecar_mode
  aca_console_allow = coalesce(var.settings.aca_console_allow, ["${var.environment.name_prefix}-caj-*"])
}
