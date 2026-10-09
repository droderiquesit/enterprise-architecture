# Control-plane logs -> Event Hubs (consumed by the Fluent Bit aggregator, shipped to Datadog as
# ddsource azure.<provider> / azure.activedirectory, see config/fluent-bit/lua/enterprise_hello.lua):
#   * subscription Activity Log (subscription-scoped azurerm_monitor_diagnostic_setting per subscription)
#   * optional Microsoft Entra ID logs (tenant-scoped azurerm_monitor_aad_diagnostic_setting)
# Only diagnostic settings are created; removal deletes only them (no log history is touched).
locals {
  activity_subscriptions = var.activity_log.enabled ? { for s in var.activity_log.subscription_ids : lower(s) => s } : {}
  native_subscriptions   = [for s in var.native_log_forwarding.subscription_log_subscription_ids : lower(s)]
  duplicate_activity     = sort([for s in keys(local.activity_subscriptions) : s if contains(local.native_subscriptions, s)])
  entra_rule_id          = coalesce(var.entra.authorization_rule_id, var.destination.authorization_rule_id)
  entra_hub              = coalesce(var.entra.eventhub_name, var.destination.eventhub_name)
}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  for_each                       = local.activity_subscriptions
  name                           = var.activity_log.setting_name
  target_resource_id             = "/subscriptions/${each.value}"
  eventhub_authorization_rule_id = var.destination.authorization_rule_id
  eventhub_name                  = var.destination.eventhub_name

  dynamic "enabled_log" {
    for_each = sort(var.activity_log.categories)
    content {
      category = enabled_log.value
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.duplicate_activity) == 0
      error_message = "Subscriptions ${join(", ", local.duplicate_activity)} already send their Activity Log through the Azure Native Datadog integration (send_subscription_logs); exporting it again via Event Hubs would ingest every event twice."
    }
  }
}

resource "azurerm_monitor_aad_diagnostic_setting" "entra" {
  count                          = var.entra.enabled ? 1 : 0
  name                           = var.entra.setting_name
  eventhub_authorization_rule_id = local.entra_rule_id
  eventhub_name                  = local.entra_hub

  dynamic "enabled_log" {
    for_each = sort(var.entra.categories)
    content {
      category = enabled_log.value
    }
  }

  lifecycle {
    precondition {
      condition     = !var.native_log_forwarding.aad_logs
      error_message = "The Azure Native Datadog integration already forwards Entra ID logs (send_aad_logs); enable only one path."
    }
    precondition {
      condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.EventHub/namespaces/[^/]+/authorizationRules/[^/]+$", local.entra_rule_id))
      error_message = "entra.authorization_rule_id must be an Event Hubs NAMESPACE authorization rule id."
    }
  }
}
