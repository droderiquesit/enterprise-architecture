# Datadog <-> Azure integration. Two supported 2026 options (README):
#  * app_registration: Datadog pulls Azure Monitor metrics + resource metadata with an Entra app
#    (datadog_integration_azure), one integration per tenant/app covering every subscription the app reads.
#  * native: Azure Native ISV "Datadog" resource (Microsoft.Datadog/monitors) with tag rules.
locals {
  # Datadog host_filters syntax: "key:value,key2:value2" include, "!key:value" exclude
  tag_filter_string   = join(",", [for f in var.metric_tag_filters : "${f.action == "Exclude" ? "!" : ""}${f.name}:${f.value}"])
  ar                  = var.mode == "app_registration"
  nat                 = var.mode == "native"
  nat_new             = local.nat && try(var.native.existing_monitor_id, null) == null
  extra_subscriptions = local.nat ? slice(var.subscription_ids, 1, length(var.subscription_ids)) : []
}

resource "datadog_integration_azure" "this" {
  count       = local.ar ? 1 : 0
  tenant_name = var.tenant_id
  client_id   = var.app_registration.client_id
  # secret-based auth only; never exported by this module
  client_secret           = var.app_registration.auth == "secret" ? var.client_secret : null
  secretless_auth_enabled = var.app_registration.auth == "secretless"

  host_filters             = local.tag_filter_string
  app_service_plan_filters = var.settings.app_service_plan_filters
  container_app_filters    = var.settings.container_app_filters

  automute                    = var.settings.automute
  cspm_enabled                = var.settings.cspm_enabled
  custom_metrics_enabled      = var.settings.custom_metrics_enabled
  resource_collection_enabled = var.settings.resource_collection_enabled
  usage_metrics_enabled       = var.settings.usage_metrics_enabled
  metrics_enabled             = true
  metrics_enabled_default     = var.settings.metrics_enabled_default
  # resource_provider_configs (per-namespace metric switches) is intentionally not wired: datadog provider
  # 4.25 fails `terraform validate` when that list is derived from an input variable (unknown-value
  # conversion bug in the framework model). Use metric_tag_filters / metrics_enabled_default instead.

  lifecycle {
    precondition {
      condition     = var.app_registration != null
      error_message = "mode = app_registration requires var.app_registration."
    }
    precondition {
      condition     = try(var.app_registration.auth, "secretless") != "secret" || var.client_secret != null
      error_message = "app_registration.auth = secret requires client_secret (pipeline input fetched from Delinea DSV)."
    }
  }
}

resource "azurerm_role_assignment" "app_monitoring_reader" {
  for_each             = local.ar && try(var.app_registration.assign_monitoring_reader, false) && try(var.app_registration.service_principal_object_id, null) != null ? toset(var.subscription_ids) : toset([])
  scope                = "/subscriptions/${each.value}"
  role_definition_name = "Monitoring Reader"
  principal_id         = var.app_registration.service_principal_object_id
  principal_type       = "ServicePrincipal"
}

# ------------------------------------------------------------------------------------------- native
resource "azurerm_datadog_monitor" "this" {
  count               = local.nat_new ? 1 : 0
  name                = var.native.name
  resource_group_name = var.native.resource_group_name
  location            = var.native.location
  sku_name            = var.native.sku_name
  monitoring_enabled  = true
  tags                = var.tags

  datadog_organization {
    api_key         = var.native_org_keys.api_key
    application_key = var.native_org_keys.application_key
  }

  user {
    name  = var.native.user_name
    email = var.native.user_email
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    precondition {
      condition     = var.native_org_keys != null && var.native.name != null && var.native.resource_group_name != null && var.native.location != null && var.native.user_email != null
      error_message = "A new native monitor needs name, resource_group_name, location, user_name/user_email and native_org_keys."
    }
  }
}

locals {
  native_monitor_id = local.nat ? (local.nat_new ? azurerm_datadog_monitor.this[0].id : var.native.existing_monitor_id) : null
}

resource "azurerm_datadog_monitor_tag_rule" "this" {
  count              = local.nat ? 1 : 0
  datadog_monitor_id = local.native_monitor_id
  name               = "default"

  log {
    aad_log_enabled          = var.native.send_aad_logs
    resource_log_enabled     = var.native.send_resource_logs
    subscription_log_enabled = var.native.send_subscription_logs
    dynamic "filter" {
      for_each = var.native.log_tag_filters
      content {
        name   = filter.value.name
        value  = filter.value.value
        action = filter.value.action
      }
    }
  }

  metric {
    dynamic "filter" {
      for_each = var.metric_tag_filters
      content {
        name   = filter.value.name
        value  = filter.value.value
        action = filter.value.action
      }
    }
  }
}

resource "azurerm_role_assignment" "native_monitoring_reader" {
  for_each             = local.nat_new && try(var.native.assign_monitoring_reader, false) ? toset(var.subscription_ids) : toset([])
  scope                = "/subscriptions/${each.value}"
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_datadog_monitor.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# AzAPI gap: azurerm 5.9 has no resource for Microsoft.Datadog/monitors/monitoredSubscriptions
# (additional subscriptions under one native monitor). API 2025-06-11.
resource "azapi_resource" "monitored_subscriptions" {
  count     = length(local.extra_subscriptions) > 0 ? 1 : 0
  type      = "Microsoft.Datadog/monitors/monitoredSubscriptions@2025-06-11"
  name      = "default"
  parent_id = local.native_monitor_id
  body = {
    properties = {
      operation = "AddBegin"
      monitoredSubscriptionList = [for s in local.extra_subscriptions : {
        subscriptionId = s
        status         = "Active"
        tagRules = {
          automuting    = var.settings.automute
          customMetrics = var.settings.custom_metrics_enabled
          logRules = {
            sendAadLogs          = false
            sendResourceLogs     = var.native.send_resource_logs
            sendSubscriptionLogs = var.native.send_subscription_logs
            filteringTags        = [for f in var.native.log_tag_filters : { name = f.name, value = f.value, action = f.action }]
          }
          metricRules = {
            filteringTags = [for f in var.metric_tag_filters : { name = f.name, value = f.value, action = f.action }]
          }
        }
      }]
    }
  }
}
