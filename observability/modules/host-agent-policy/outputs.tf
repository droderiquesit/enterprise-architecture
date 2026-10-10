output "assignment_id" {
  description = "Initiative assignment id (subscription or management-group scope)."
  value       = local.assignment_id
}

output "policy_set_definition_id" {
  description = "Initiative (policy set) id."
  value       = local.set_id
}

output "policy_definition_ids" {
  description = "Custom DeployIfNotExists definitions: vm, vmss."
  value       = { for k, d in azurerm_policy_definition.agent : k => d.id }
}

output "members" {
  description = "Initiative members (policy_definition_reference_id -> application key + resource kind)."
  value       = local.members
}

output "remediation_identity" {
  description = "User-assigned identity of the assignment {id, principal_id} and its custom role id."
  value = {
    id                 = azurerm_user_assigned_identity.remediation.id
    principal_id       = azurerm_user_assigned_identity.remediation.principal_id
    role_definition_id = azurerm_role_definition.remediation.role_definition_resource_id
  }
}

output "remediations" {
  description = "Remediation task ids per member (empty when disabled)."
  value = merge(
    { for k, r in azurerm_subscription_policy_remediation.agent : k => r.id },
    { for k, r in azurerm_management_group_policy_remediation.agent : k => r.id },
  )
}

output "enrollment_tag" {
  description = "Tag platform owners set on VMs / VMSS to enrol them."
  value       = var.enrollment_tag
}
