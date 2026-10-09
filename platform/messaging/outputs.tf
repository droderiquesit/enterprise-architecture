output "contract" {
  description = "platform-messaging contract v1 (catalog/contracts/platform-messaging.v1.schema.json). No keys or connection strings."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    namespace_id        = azurerm_servicebus_namespace.this.id
    namespace_name      = azurerm_servicebus_namespace.this.name
    fqdn                = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
    sku                 = var.settings.sku
    local_auth_enabled  = false
    private             = local.private
    topic = {
      name = azurerm_servicebus_topic.order_events.name
      id   = azurerm_servicebus_topic.order_events.id
    }
    subscriptions = {
      for k, s in azurerm_servicebus_subscription.this : k => {
        id                 = s.id
        name               = s.name
        consumer           = var.settings.subscriptions[k].consumer
        max_delivery_count = s.max_delivery_count
      }
    }
    queues = {
      (var.settings.queue_name) = {
        id       = azurerm_servicebus_queue.batch_items.id
        name     = azurerm_servicebus_queue.batch_items.name
        consumer = var.settings.queue_consumer
      }
    }
    grants         = { for k, g in local.active_grants : k => { identity = g.identity, entity = g.entity, kind = g.kind, role = g.role } }
    skipped_grants = local.skipped_grants
  }
}
