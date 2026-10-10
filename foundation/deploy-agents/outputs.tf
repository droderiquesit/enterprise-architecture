output "contract" {
  description = "foundation-deploy-agents contract v1 (catalog/contracts/foundation-deploy-agents.v1.schema.json)."
  value = {
    mode                   = var.settings.mode
    resource_group_name    = azurerm_resource_group.agents.name
    subnet_id              = local.subnet.id
    identity_id            = local.identity.id
    identity_client_id     = local.identity.client_id
    vmss_id                = local.vmss_mode ? azurerm_linux_virtual_machine_scale_set.agents[0].id : null
    vmss_name              = local.vmss_mode ? azurerm_linux_virtual_machine_scale_set.agents[0].name : null
    managed_devops_pool_id = local.mdp_mode ? azurerm_managed_devops_pool.this[0].id : null
    dev_center_project_id  = local.mdp_mode ? azurerm_dev_center_project.this[0].id : null
    # Name to use in Azure DevOps (VMSS: the elastic pool you create over this scale set; MDP: the pool name).
    agent_pool_name = local.vmss_mode ? azurerm_linux_virtual_machine_scale_set.agents[0].name : azurerm_managed_devops_pool.this[0].name
  }
}

output "copilot_review_pool" {
  description = "Managed DevOps Pool for GitHub Copilot code review (select it in Organization settings > Repos > Repositories)."
  value       = local.copilot_pool.enabled ? { id = azurerm_managed_devops_pool.copilot_review[0].id, name = azurerm_managed_devops_pool.copilot_review[0].name } : null
}
