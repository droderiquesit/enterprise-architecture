mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-governance-dev-sec" }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/ag" }
  }
}

mock_provider "time" {
  override_during = plan
  mock_resource "time_static" {
    defaults = { rfc3339 = "2026-10-09T12:34:56Z" }
  }
}

variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = length(azurerm_consumption_budget_subscription.this) == 1 && azurerm_consumption_budget_subscription.this[0].amount == 300
    error_message = "subscription budget expected by default"
  }
  assert {
    condition     = toset([for n in azurerm_consumption_budget_subscription.this[0].notification : "${n.threshold_type}:${n.threshold}"]) == toset(["Actual:50", "Actual:80", "Actual:100", "Forecasted:80", "Forecasted:100"])
    error_message = "budget notifications at 50/80/100 actual and 80/100 forecast expected"
  }
  assert {
    condition     = alltrue([for n in azurerm_consumption_budget_subscription.this[0].notification : contains(n.contact_emails, "platform-team@example.com") && length(n.contact_groups) == 1])
    error_message = "notifications must go to the owner email and the action group"
  }
  assert {
    condition     = azurerm_consumption_budget_subscription.this[0].time_period[0].start_date == "2026-10-01T00:00:00Z"
    error_message = "budget starts on the first day of the creation month"
  }
  assert {
    condition     = length(azurerm_consumption_budget_subscription.this[0].filter[0].tag) == 2
    error_message = "budget filtered to lab tags"
  }
  assert {
    condition     = toset(keys(azurerm_subscription_policy_assignment.require_rg_tag)) == toset(["env", "owner", "expires_on"])
    error_message = "env/owner/expires_on RG tag policies expected"
  }
  assert {
    condition     = azurerm_subscription_policy_assignment.require_rg_tag["env"].policy_definition_id == "/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025"
    error_message = "built-in 'Require a tag on resource groups' expected"
  }
  assert {
    condition     = azurerm_subscription_policy_assignment.nic_no_public_ip[0].enforce == false
    error_message = "NIC public-IP policy is audit-only (DoNotEnforce) by default"
  }
  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.allowed_locations.parameters).listOfAllowedLocations.value == ["swedencentral"]
    error_message = "allowed locations defaults to the environment location"
  }
  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.allowed_locations.metadata).expires_on == "2026-12-31"
    error_message = "expiration metadata on assignments"
  }
  assert {
    condition     = output.contract.budget.caps_spend == false
    error_message = "contract must state budgets do not cap spend"
  }
}

run "resource_group_budgets" {
  command = plan
  variables {
    settings = {
      budget = {
        scope              = "resource_group"
        resource_group_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-network-dev-sec"]
      }
      policy = { nic_public_ip_allowlisted_rg_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/jump"] }
    }
  }
  assert {
    condition     = length(azurerm_consumption_budget_subscription.this) == 0 && length(azurerm_consumption_budget_resource_group.this) == 1
    error_message = "resource-group scoped budget expected"
  }
  assert {
    condition     = contains(azurerm_subscription_policy_assignment.nic_no_public_ip[0].not_scopes, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/jump")
    error_message = "allowlisted RGs excluded from NIC policy"
  }
}

run "too_many_notifications_rejected" {
  command = plan
  variables {
    settings = { budget = { actual_thresholds = [25, 50, 75, 100], forecast_thresholds = [90, 100] } }
  }
  expect_failures = [var.settings]
}

run "environment_budget_global" {
  command = plan
  variables {
    budget = { monthly_amount = 500, currency = "USD", contact_emails = ["finops@example.com"] }
  }
  assert {
    condition     = azurerm_consumption_budget_subscription.this[0].amount == 500 && alltrue([for n in azurerm_consumption_budget_subscription.this[0].notification : contains(n.contact_emails, "finops@example.com")])
    error_message = "environment.yaml budget.monthly_amount / contact_emails apply when settings.budget does not override them."
  }
}

run "settings_override_budget_global" {
  command = plan
  variables {
    budget   = { monthly_amount = 500 }
    settings = { budget = { amount = 120 } }
  }
  assert {
    condition     = azurerm_consumption_budget_subscription.this[0].amount == 120
    error_message = "settings.budget.amount overrides the environment global."
  }
}

run "copilot_review_budget_filters_the_copilot_meter" {
  command = plan
  assert {
    condition     = length(azurerm_consumption_budget_subscription.copilot_review) == 1
    error_message = "A Copilot code review budget alert must exist by default."
  }
}
