output "contract" {
  description = "foundation-governance contract v1 (catalog/contracts/foundation-governance.v1.schema.json)."
  value = {
    resource_group_name = azurerm_resource_group.governance.name
    action_group_id     = azurerm_monitor_action_group.budget.id
    budget = {
      scope  = local.budget.scope
      amount = local.budget.amount
      ids = concat(
        azurerm_consumption_budget_subscription.this[*].id,
        [for b in azurerm_consumption_budget_resource_group.this : b.id],
      )
      caps_spend = false # Azure budgets only alert.
    }
    policy_assignment_ids = merge(
      { for k, v in azurerm_subscription_policy_assignment.require_rg_tag : "require-rg-tag-${k}" => v.id },
      { "allowed-locations" = azurerm_subscription_policy_assignment.allowed_locations.id },
      { for v in azurerm_subscription_policy_assignment.nic_no_public_ip : "nic-no-public-ip" => v.id },
    )
    expires_on = var.environment.expires_on
  }
}
