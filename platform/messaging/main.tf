resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  premium    = var.settings.sku == "Premium"
  identities = var.foundation_identity.identities
  private    = local.premium && var.settings.private_endpoint_enabled

  ip_rules = distinct(concat(
    var.settings.allowed_ip_ranges,
    var.settings.allow_egress_ips ? var.foundation_network.egress.public_ips : [],
  ))

  # Public network access: Standard always public (Entra-only). Premium follows the setting.
  public_network_access = local.premium ? var.settings.public_network_access_enabled : true

  # Data-plane grants: key => {identity, scope kind, entity, role}
  grants = merge(
    { for k in var.settings.topic_sender_identities : "topic-send-${k}" => { identity = k, kind = "topic", entity = var.settings.topic_name, role = "Azure Service Bus Data Sender" } },
    { for k in concat(var.settings.queue_sender_identities, var.settings.logic_app_identities) : "queue-send-${k}" => { identity = k, kind = "queue", entity = var.settings.queue_name, role = "Azure Service Bus Data Sender" } },
    { for s, cfg in var.settings.subscriptions : "sub-recv-${s}-${cfg.consumer}" => { identity = cfg.consumer, kind = "subscription", entity = s, role = "Azure Service Bus Data Receiver" } },
    { "queue-recv-${var.settings.queue_consumer}" = { identity = var.settings.queue_consumer, kind = "queue", entity = var.settings.queue_name, role = "Azure Service Bus Data Receiver" } },
    var.settings.queue_scaler_owner_enabled ? { "queue-scaler-${var.settings.queue_consumer}" = { identity = var.settings.queue_consumer, kind = "queue", entity = var.settings.queue_name, role = "Azure Service Bus Data Owner" } } : {},
  )
  active_grants  = { for k, g in local.grants : k => g if contains(keys(local.identities), g.identity) }
  skipped_grants = sort([for k, g in local.grants : k if !contains(keys(local.identities), g.identity)])
}

resource "azurerm_servicebus_namespace" "this" {
  #checkov:skip=CKV_AZURE_202:A namespace identity is only needed for customer-managed keys, which the synthetic-data lab does not use.
  #checkov:skip=CKV_AZURE_201:Microsoft-managed encryption keys are sufficient for synthetic data (CMK is Premium-only).
  #checkov:skip=CKV_AZURE_199:Infrastructure (double) encryption requires CMK on Premium; not used in the lab.
  name                = "${local.names.service_bus}-${module.naming.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  sku                 = var.settings.sku
  tags                = local.tags

  capacity                      = local.premium ? var.settings.premium_capacity : 0
  premium_messaging_partitions  = local.premium ? var.settings.premium_partitions : 0
  local_auth_enabled            = false # Entra ID only; no SAS keys are used anywhere
  minimum_tls_version           = "1.2"
  public_network_access_enabled = local.public_network_access

  dynamic "network_rule_set" {
    for_each = local.premium || length(local.ip_rules) > 0 ? [1] : []
    content {
      default_action                = length(local.ip_rules) > 0 || !local.public_network_access ? "Deny" : "Allow"
      public_network_access_enabled = local.public_network_access
      ip_rules                      = local.ip_rules
      trusted_services_allowed      = local.premium # Standard has no trusted-services bypass
    }
  }
}

module "private_endpoint" {
  count  = local.private ? 1 : 0
  source = "../../foundation/modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-sbns"
  resource_group_name  = azurerm_resource_group.this.name
  location             = local.location
  subnet_id            = local.subnets["private-endpoints"].id
  target_resource_id   = azurerm_servicebus_namespace.this.id
  subresource_names    = ["namespace"]
  private_dns_zone_ids = try([var.foundation_network.private_dns_zones["servicebus"].id], [])
  tags                 = local.tags
}

# ---------------------------------------------------------------- entities
resource "azurerm_servicebus_topic" "order_events" {
  name                                    = var.settings.topic_name
  namespace_id                            = azurerm_servicebus_namespace.this.id
  max_size_in_megabytes                   = var.settings.topic_max_size_mb
  default_message_ttl                     = var.settings.message_ttl
  requires_duplicate_detection            = true # publishers set MessageId = order id (idempotency)
  duplicate_detection_history_time_window = var.settings.duplicate_detection
  batched_operations_enabled              = true
  partitioning_enabled                    = false
}

resource "azurerm_servicebus_subscription" "this" {
  for_each = var.settings.subscriptions

  name                                      = each.key
  topic_id                                  = azurerm_servicebus_topic.order_events.id
  max_delivery_count                        = each.value.max_delivery_count
  lock_duration                             = each.value.lock_duration
  default_message_ttl                       = var.settings.message_ttl
  dead_lettering_on_message_expiration      = true
  dead_lettering_on_filter_evaluation_error = true
  batched_operations_enabled                = true
  requires_session                          = false
}

resource "azurerm_servicebus_queue" "batch_items" {
  name                                    = var.settings.queue_name
  namespace_id                            = azurerm_servicebus_namespace.this.id
  max_delivery_count                      = var.settings.queue_max_delivery_count
  lock_duration                           = var.settings.queue_lock_duration
  default_message_ttl                     = var.settings.message_ttl
  dead_lettering_on_message_expiration    = true
  requires_duplicate_detection            = true
  duplicate_detection_history_time_window = var.settings.duplicate_detection
  batched_operations_enabled              = true
  partitioning_enabled                    = false
}

# ---------------------------------------------------------------- RBAC (data plane)
locals {
  scopes = {
    topic        = { (var.settings.topic_name) = azurerm_servicebus_topic.order_events.id }
    queue        = { (var.settings.queue_name) = azurerm_servicebus_queue.batch_items.id }
    subscription = { for k, s in azurerm_servicebus_subscription.this : k => s.id }
  }
}

resource "azurerm_role_assignment" "data" {
  for_each = local.active_grants

  scope                = local.scopes[each.value.kind][each.value.entity]
  role_definition_name = each.value.role
  principal_id         = local.identities[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
  description          = "${each.value.role} on ${each.value.kind} ${each.value.entity} for ${each.value.identity}"
}
