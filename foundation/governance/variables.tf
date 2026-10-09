variable "environment" {
  description = "Environment globals (ADR-0001 §6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "settings" {
  description = "Component settings (components.foundation-governance). See README."
  type = object({
    budget = optional(object({
      # Azure budgets ALERT; they never stop or cap spend.
      # Override of the environment global `budget.monthly_amount` (var.budget); 300 when neither is set.
      amount = optional(number)
      # "subscription" (default) or "resource_group" (one budget per id in resource_group_ids).
      scope               = optional(string, "subscription")
      resource_group_ids  = optional(list(string), [])
      contact_emails      = optional(list(string), [])
      actual_thresholds   = optional(list(number), [50, 80, 100])
      forecast_thresholds = optional(list(number), [80, 100])
      # Only count cost of resources tagged application=enterprise-hello + env=<env> (safe in shared subscriptions).
      filter_by_lab_tags = optional(bool, true)
      # YYYY-MM-01; default = first day of the month in which the budget is first created (time_static).
      start_date = optional(string)
      # Optional end (YYYY-MM-DD); default none (Azure applies 10 years).
      end_date = optional(string)
    }), {})

    action_group_short_name = optional(string, "ehlabbudget")

    policy = optional(object({
      # Assignments are at subscription scope. enforce=false => enforcementMode DoNotEnforce ("audit mode":
      # compliance is evaluated and reported, nothing is denied).
      allowed_locations          = optional(list(string)) # default [environment.location]
      allowed_locations_enforce  = optional(bool, true)
      required_rg_tags           = optional(list(string), ["env", "owner", "expires_on"])
      required_rg_tags_enforce   = optional(bool, false)
      deny_nic_public_ip         = optional(bool, true)
      deny_nic_public_ip_enforce = optional(bool, false)
      # Resource group IDs excluded from the NIC public-IP policy (e.g. a jump-host RG).
      nic_public_ip_allowlisted_rg_ids = optional(list(string), [])
      # Extra scopes excluded from every assignment (e.g. AKS node / ARO managed resource groups).
      not_scopes = optional(list(string), [])
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["subscription", "resource_group"], var.settings.budget.scope)
    error_message = "budget.scope must be subscription or resource_group."
  }
  validation {
    condition     = var.settings.budget.scope == "subscription" || length(var.settings.budget.resource_group_ids) > 0
    error_message = "budget.scope = resource_group requires budget.resource_group_ids."
  }
  validation {
    condition     = length(var.settings.budget.actual_thresholds) + length(var.settings.budget.forecast_thresholds) <= 5
    error_message = "Azure budgets support at most 5 notifications."
  }
  validation {
    condition     = var.settings.budget.start_date == null || can(regex("^\\d{4}-\\d{2}-01$", var.settings.budget.start_date))
    error_message = "budget.start_date must be the first day of a month (YYYY-MM-01)."
  }
  validation {
    condition     = length(var.settings.action_group_short_name) <= 12
    error_message = "action_group_short_name must be <= 12 characters."
  }
}

variable "budget" {
  description = "Environment global `budget` (environments/<env>/environment.yaml; rendered by tools/config/render.py because this root declares it). settings.budget.amount / contact_emails override it."
  type = object({
    monthly_amount = optional(number)
    currency       = optional(string)
    contact_emails = optional(list(string), [])
  })
  default = null
}
