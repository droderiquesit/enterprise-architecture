# Event Hubs for diagnostic-settings export (app-logs + platform-logs + activity-logs) consumed by the aggregator's
# Kafka input.
locals {
  eh_create         = var.event_hub.mode == "create"
  eh_enabled        = var.event_hub.mode != "none"
  eh_namespace_name = coalesce(var.names.eventhub_namespace, substr("${var.name_prefix}-evhns", 0, 50))
  activity_hub      = coalesce(var.event_hub.activity_logs_hub, var.event_hub.platform_logs_hub)
  hubs = local.eh_create ? merge(
    {
      app      = var.event_hub.app_logs_hub
      platform = var.event_hub.platform_logs_hub
    },
    local.activity_hub != var.event_hub.platform_logs_hub ? { activity = local.activity_hub } : {},
  ) : {}
  eventhub_topics = join(",", distinct([var.event_hub.app_logs_hub, var.event_hub.platform_logs_hub, local.activity_hub]))
}

resource "azurerm_eventhub_namespace" "this" {
  count               = local.eh_create ? 1 : 0
  name                = local.eh_namespace_name
  resource_group_name = var.resource_group.name
  location            = var.location
  sku                 = var.event_hub.sku
  capacity            = var.event_hub.capacity
  # Kafka endpoint is always on for Standard+. SAS (local auth) stays enabled ONLY because Fluent Bit's
  # kafka input cannot obtain Entra tokens from the Container Apps managed-identity endpoint
  # (librdkafka azure_imds needs the VM IMDS) -> documented exception, see README.
  local_authentication_enabled = true
  minimum_tls_version          = "1.2"
  auto_inflate_enabled         = var.event_hub.auto_inflate_max_throughput_units > 0
  maximum_throughput_units     = var.event_hub.auto_inflate_max_throughput_units > 0 ? var.event_hub.auto_inflate_max_throughput_units : null
  # Private by default: deny public traffic except trusted Microsoft services (Azure Monitor diagnostic
  # settings are a trusted service); collectors reach the namespace through the private endpoint.
  public_network_access_enabled = true
  network_rulesets = [{
    default_action                 = "Deny"
    public_network_access_enabled  = true
    trusted_service_access_enabled = true
    ip_rule                        = []
    virtual_network_rule           = []
  }]
  tags = var.tags
}

resource "azurerm_eventhub" "hub" {
  for_each          = local.hubs
  name              = each.value
  namespace_id      = azurerm_eventhub_namespace.this[0].id
  partition_count   = var.event_hub.partition_count
  message_retention = var.event_hub.message_retention_days
}

resource "azurerm_eventhub_consumer_group" "fluentbit" {
  for_each            = local.hubs
  name                = var.event_hub.consumer_group
  namespace_name      = azurerm_eventhub_namespace.this[0].name
  eventhub_name       = azurerm_eventhub.hub[each.key].name
  resource_group_name = var.resource_group.name
  user_metadata       = "fluent-bit aggregator (kafka input)"
}

# Diagnostic settings require Manage+Send+Listen on the namespace rule they stream with.
resource "azurerm_eventhub_namespace_authorization_rule" "diagnostics" {
  count               = local.eh_create ? 1 : 0
  name                = "diagnostic-settings-send"
  namespace_name      = azurerm_eventhub_namespace.this[0].name
  resource_group_name = var.resource_group.name
  listen              = true
  send                = true
  manage              = true
}

# Listen-only rule for the Fluent Bit kafka input (SASL PLAIN, username "$ConnectionString").
resource "azurerm_eventhub_namespace_authorization_rule" "fluentbit_listen" {
  count               = local.eh_create ? 1 : 0
  name                = "fluent-bit-listen"
  namespace_name      = azurerm_eventhub_namespace.this[0].name
  resource_group_name = var.resource_group.name
  listen              = true
  send                = false
  manage              = false
}

# The generated listen connection string is NOT written to any vault by Terraform: it is exposed only as the
# sensitive output generated_secrets (tools/secrets/publish.py copies it to DSV after apply) and read by the
# aggregator from DSV. The authorization rule itself necessarily holds its keys in state (README "Secrets in state").

resource "azurerm_private_endpoint" "eventhub" {
  count               = local.eh_create && var.event_hub.private_endpoint != null ? 1 : 0
  name                = "${local.eh_namespace_name}-pep"
  resource_group_name = var.resource_group.name
  location            = var.location
  subnet_id           = var.event_hub.private_endpoint.subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${local.eh_namespace_name}-psc"
    private_connection_resource_id = azurerm_eventhub_namespace.this[0].id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.event_hub.private_endpoint.private_dns_zone_id]
  }
}

locals {
  eh_namespace_id = local.eh_create ? azurerm_eventhub_namespace.this[0].id : var.event_hub.namespace_id
  eh_namespace_name_effective = local.eh_enabled ? (
    local.eh_create ? azurerm_eventhub_namespace.this[0].name : element(split("/", var.event_hub.namespace_id), length(split("/", var.event_hub.namespace_id)) - 1)
  ) : null
  eh_fqdn         = local.eh_enabled ? coalesce(var.event_hub.namespace_fqdn, "${local.eh_namespace_name_effective}.servicebus.windows.net") : null
  eh_send_rule_id = local.eh_create ? azurerm_eventhub_namespace_authorization_rule.diagnostics[0].id : var.event_hub.send_authorization_rule_id
  eh_listen_ref   = var.event_hub.listen_connection_string_ref
}
