# Diagnostic settings for EXISTING resources -> Event Hubs (app-logs / platform-logs).
# Only categories a resource really supports (azurerm_monitor_diagnostic_categories) are enabled, and a
# setting is created only when at least one category remains, so unsupported resource types get nothing.
# Platform categories come from the maintained tier policy (category-policy.json: security | standard | verbose).
# Metrics are never exported here (the Datadog Azure integration collects platform metrics).
locals {
  tiers      = ["security", "standard", "verbose"]
  tier_index = { security = 0, standard = 1, verbose = 2 }
  policy     = var.category_policy != null ? var.category_policy : jsondecode(file("${path.module}/category-policy.json")).types

  # type -> tier -> cumulative category list
  policy_lists = {
    for t, p in local.policy : t => {
      for tier in local.tiers : tier => distinct(flatten([for tt in slice(local.tiers, 0, local.tier_index[tier] + 1) : try(p[tt], [])]))
    }
  }

  # resource type from the id: provider namespace + every child type segment, lower case
  resource_types = {
    for k, r in var.resources : k => (
      join("/", concat(
        [lower(regex("(?i)/providers/([^/]+)/", r.id)[0])],
        [for i, seg in split("/", regex("(?i)/providers/[^/]+/(.+)$", r.id)[0]) : lower(seg) if i % 2 == 0],
      ))
    )
  }

  known_types = setunion(
    keys(var.app_log_categories), keys(local.policy), keys(var.platform_log_allowlist_overrides),
    var.platform_log_allowlist == null ? [] : keys(var.platform_log_allowlist),
  )

  # never stream an Event Hubs namespace into itself (feedback loop: every write produces more logs)
  destination_namespace = lower(try(regex("(?i)^(.+/namespaces/[^/]+)/authorizationRules/", var.destination.authorization_rule_id)[0], ""))
  self_referencing      = sort([for k, r in var.resources : k if lower(r.id) == local.destination_namespace])

  # only resources whose type is known to support diagnostic settings are queried
  queried = {
    for k, r in var.resources : k => r
    if contains(local.known_types, local.resource_types[k]) && !contains(local.self_referencing, k)
  }

  effective_tier = { for k, r in local.queried : k => coalesce(r.tier, var.platform_log_tier) }

  selected_platform = {
    for k, r in local.queried : k => (
      r.platform_categories != null ? r.platform_categories : (
        var.platform_log_allowlist != null ? lookup(var.platform_log_allowlist, local.resource_types[k], []) : (
          contains(keys(var.platform_log_allowlist_overrides), local.resource_types[k]) ? var.platform_log_allowlist_overrides[local.resource_types[k]] : try(local.policy_lists[local.resource_types[k]][local.effective_tier[k]], [])
        )
      )
    )
  }

  # e.g. full kube-audit replaces kube-audit-admin (the same events would otherwise be sent twice)
  superseded = {
    for k, sel in local.selected_platform : k => flatten([
      for c, drops in try(local.policy[local.resource_types[k]].supersedes, {}) : drops if contains(sel, c)
    ])
  }
}

data "azurerm_monitor_diagnostic_categories" "this" {
  for_each    = local.queried
  resource_id = each.value.id
}

locals {
  supported = { for k, d in data.azurerm_monitor_diagnostic_categories.this : k => toset(d.log_category_types) }

  app_categories = {
    for k, r in local.queried : k => sort(tolist(setintersection(
      local.supported[k],
      toset(lookup(var.app_log_categories, local.resource_types[k], [])),
    ))) if r.app_log_route == "eventhub"
  }

  platform_categories = {
    for k, r in local.queried : k => sort(tolist(setsubtract(
      setintersection(local.supported[k], toset(local.selected_platform[k])),
      # an app-log category never goes to the platform hub (no duplicates even if mis-listed)
      setunion(toset(lookup(var.app_log_categories, local.resource_types[k], [])), toset(local.superseded[k])),
    ))) if r.platform_logs
  }

  app_settings      = { for k, c in local.app_categories : k => c if length(c) > 0 }
  platform_settings = { for k, c in local.platform_categories : k => c if length(c) > 0 }

  unsupported = sort([for k in keys(var.resources) : k if !contains(keys(local.queried), k) && !contains(local.self_referencing, k)])
}

resource "azurerm_monitor_diagnostic_setting" "app_logs" {
  for_each                       = local.app_settings
  name                           = "${var.setting_name_prefix}-app-logs"
  target_resource_id             = var.resources[each.key].id
  eventhub_authorization_rule_id = var.destination.authorization_rule_id
  eventhub_name                  = var.destination.app_logs_hub

  dynamic "enabled_log" {
    for_each = each.value
    content {
      category = enabled_log.value
    }
  }

  lifecycle {
    precondition {
      condition     = var.resources[each.key].location == null || var.destination.location == null || lower(replace(coalesce(var.resources[each.key].location, ""), " ", "")) == lower(replace(coalesce(var.destination.location, ""), " ", ""))
      error_message = "Diagnostic settings can only stream to an Event Hub in the same region as the resource (${each.key})."
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "platform_logs" {
  for_each                       = local.platform_settings
  name                           = "${var.setting_name_prefix}-platform-logs"
  target_resource_id             = var.resources[each.key].id
  eventhub_authorization_rule_id = var.destination.authorization_rule_id
  eventhub_name                  = var.destination.platform_logs_hub

  dynamic "enabled_log" {
    for_each = each.value
    content {
      category = enabled_log.value
    }
  }

  lifecycle {
    precondition {
      condition     = var.resources[each.key].location == null || var.destination.location == null || lower(replace(coalesce(var.resources[each.key].location, ""), " ", "")) == lower(replace(coalesce(var.destination.location, ""), " ", ""))
      error_message = "Diagnostic settings can only stream to an Event Hub in the same region as the resource (${each.key})."
    }
  }
}
