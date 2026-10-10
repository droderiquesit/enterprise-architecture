module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "governance"
}

module "tags" {
  source      = "../modules/tags"
  environment = var.environment
  component   = "foundation-governance"
  layer       = "foundation"
  domain      = "governance"
}

locals {
  names           = module.naming.names
  tags            = module.tags.tags
  subscription_id = "/subscriptions/${var.environment.subscription_id}"
  budget = merge(var.settings.budget, {
    enabled        = coalesce(var.settings.budget.enabled, try(var.budget.enabled, null), true)
    amount         = coalesce(var.settings.budget.amount, try(var.budget.monthly_amount, null), 300)
    contact_emails = length(var.settings.budget.contact_emails) > 0 ? var.settings.budget.contact_emails : try(coalesce(var.budget.contact_emails, []), [])
  })
  policy = var.settings.policy

  contact_emails = length(local.budget.contact_emails) > 0 ? local.budget.contact_emails : (
    can(regex("^[^@\\s]+@[^@\\s]+$", var.environment.owner)) ? [var.environment.owner] : []
  )

  notifications = concat(
    [for t in local.budget.actual_thresholds : { threshold = t, type = "Actual" }],
    [for t in local.budget.forecast_thresholds : { threshold = t, type = "Forecasted" }],
  )

  budget_start = coalesce(
    local.budget.start_date == null ? null : "${local.budget.start_date}T00:00:00Z",
    formatdate("YYYY-MM-01'T'00:00:00Z", time_static.budget_start.rfc3339),
  )
  budget_end = local.budget.end_date == null ? null : "${local.budget.end_date}T00:00:00Z"

  # Expiration metadata recorded on every policy assignment (ADR §6: lab environments expire).
  assignment_metadata = jsonencode({
    application = "enterprise-hello"
    env         = var.environment.name
    owner       = var.environment.owner
    expires_on  = var.environment.expires_on
    managed_by  = "terraform/foundation-governance"
    repository  = "azure-enterprise-observability-lab"
  })

  # Built-in policy definitions (verified on Microsoft Learn 2026-10-09).
  policy_definitions = {
    require_rg_tag    = "/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025" # Require a tag on resource groups (deny)
    allowed_locations = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c" # Allowed locations (deny; excludes RGs + 'global')
    nic_no_public_ip  = "/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114" # Network interfaces should not have public IPs (deny)
  }
  allowed_locations = coalesce(local.policy.allowed_locations, [var.environment.location])
}

resource "azurerm_resource_group" "governance" {
  name     = local.names.resource_group
  location = var.environment.location
  tags     = local.tags
}

# ------------------------------------------------------------------ budget + action group
resource "azurerm_monitor_action_group" "budget" {
  name                = local.names.action_group
  resource_group_name = azurerm_resource_group.governance.name
  short_name          = var.settings.action_group_short_name
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = local.contact_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "time_static" "budget_start" {}

resource "azurerm_consumption_budget_subscription" "this" {
  count = local.budget.enabled && local.budget.scope == "subscription" ? 1 : 0

  name            = local.names.budget
  subscription_id = local.subscription_id
  amount          = local.budget.amount
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start
    end_date   = local.budget_end
  }

  dynamic "filter" {
    for_each = local.budget.filter_by_lab_tags ? [1] : []
    content {
      tag {
        name     = "application"
        operator = "In"
        values   = ["enterprise-hello"]
      }
      tag {
        name     = "env"
        operator = "In"
        values   = [var.environment.name]
      }
    }
  }

  dynamic "notification" {
    for_each = local.notifications
    content {
      enabled        = true
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      operator       = notification.value.type == "Forecasted" ? "GreaterThan" : "GreaterThanOrEqualTo"
      contact_emails = local.contact_emails
      contact_groups = [azurerm_monitor_action_group.budget.id]
    }
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date] # start date is fixed at creation
  }
}

resource "azurerm_consumption_budget_resource_group" "this" {
  for_each = local.budget.enabled && local.budget.scope == "resource_group" ? toset(local.budget.resource_group_ids) : toset([])

  name              = "${local.names.budget}-${element(split("/", each.value), length(split("/", each.value)) - 1)}"
  resource_group_id = each.value
  amount            = local.budget.amount
  time_grain        = "Monthly"

  time_period {
    start_date = local.budget_start
    end_date   = local.budget_end
  }

  dynamic "notification" {
    for_each = local.notifications
    content {
      enabled        = true
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      operator       = notification.value.type == "Forecasted" ? "GreaterThan" : "GreaterThanOrEqualTo"
      contact_emails = local.contact_emails
      contact_groups = [azurerm_monitor_action_group.budget.id]
    }
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}

# ------------------------------------------------------------------ policy assignments (subscription scope)
resource "azurerm_subscription_policy_assignment" "require_rg_tag" {
  for_each = toset(local.policy.required_rg_tags)

  name                 = "eh-${var.environment.name}-rg-tag-${replace(each.value, "_", "-")}"
  display_name         = "[enterprise-hello ${var.environment.name}] Require tag '${each.value}' on resource groups"
  subscription_id      = local.subscription_id
  policy_definition_id = local.policy_definitions.require_rg_tag
  enforce              = local.policy.required_rg_tags_enforce
  not_scopes           = local.policy.not_scopes
  metadata             = local.assignment_metadata
  parameters           = jsonencode({ tagName = { value = each.value } })

  non_compliance_message {
    content = "Resource groups must carry the '${each.value}' tag (lab expiry/ownership tracking)."
  }
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "eh-${var.environment.name}-allowed-locations"
  display_name         = "[enterprise-hello ${var.environment.name}] Allowed locations"
  subscription_id      = local.subscription_id
  policy_definition_id = local.policy_definitions.allowed_locations
  enforce              = local.policy.allowed_locations_enforce
  not_scopes           = local.policy.not_scopes
  metadata             = local.assignment_metadata
  parameters           = jsonencode({ listOfAllowedLocations = { value = local.allowed_locations } })

  non_compliance_message {
    content = "Lab resources must be deployed to: ${join(", ", local.allowed_locations)}."
  }
}

resource "azurerm_subscription_policy_assignment" "nic_no_public_ip" {
  count = local.policy.deny_nic_public_ip ? 1 : 0

  name                 = "eh-${var.environment.name}-nic-no-public-ip"
  display_name         = "[enterprise-hello ${var.environment.name}] Network interfaces should not have public IPs"
  subscription_id      = local.subscription_id
  policy_definition_id = local.policy_definitions.nic_no_public_ip
  enforce              = local.policy.deny_nic_public_ip_enforce
  not_scopes           = concat(local.policy.not_scopes, local.policy.nic_public_ip_allowlisted_rg_ids)
  metadata             = local.assignment_metadata

  non_compliance_message {
    content = "Lab NICs are private; use Bastion / private agents. Exceptions: allowlisted resource groups only."
  }
}

# ------------------------------------------------------------- Copilot code review spend (alert only)
locals {
  copilot_budget      = var.settings.copilot_review_budget
  copilot_budget_subs = "/subscriptions/${coalesce(local.copilot_budget.subscription_id, var.environment.subscription_id)}"
  copilot_notifications = concat(
    [for t in local.copilot_budget.actual_thresholds : { threshold = t, type = "Actual" }],
    [for t in local.copilot_budget.forecast_thresholds : { threshold = t, type = "Forecasted" }],
  )
}

resource "azurerm_consumption_budget_subscription" "copilot_review" {
  count = local.copilot_budget.enabled ? 1 : 0

  name            = "${local.names.budget}-copilot-review"
  subscription_id = local.copilot_budget_subs
  amount          = local.copilot_budget.amount
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start
    end_date   = local.budget_end
  }

  filter {
    dimension {
      name     = "MeterCategory"
      operator = "In"
      values   = ["GitHub"]
    }
    dimension {
      name     = "MeterSubCategory"
      operator = "In"
      values   = ["GitHub Copilot for AzDO"]
    }
  }

  dynamic "notification" {
    for_each = local.copilot_notifications
    content {
      enabled        = true
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      operator       = notification.value.type == "Forecasted" ? "GreaterThan" : "GreaterThanOrEqualTo"
      contact_emails = local.contact_emails
      contact_groups = [azurerm_monitor_action_group.budget.id]
    }
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date] # start date is fixed at creation
  }
}
