output "contract" {
  description = "platform-specialized-compute contract v1 (catalog/contracts/platform-specialized-compute.v1.schema.json)."
  value = {
    resource_group_name = local.any ? azurerm_resource_group.this[0].name : null
    vms = {
      for k, v in local.vms : k => {
        id                    = azurerm_linux_virtual_machine.this[k].id
        name                  = azurerm_linux_virtual_machine.this[k].name
        os_type               = "Linux"
        size                  = v.size
        private_ip            = azurerm_network_interface.this[k].private_ip_address
        workload              = v.identity
        identity_principal_id = local.identities[v.identity].principal_id
        kind                  = k == "cvm" ? "confidential" : (k == "dh" ? "dedicated-host" : "gpu")
      }
    }
    dedicated_host_id = local.s.dedicated_host.enabled ? azurerm_dedicated_host.this[0].id : null
    automation = local.s.automation.enabled ? {
      account_id    = azurerm_automation_account.this[0].id
      account_name  = azurerm_automation_account.this[0].name
      schedule_name = azurerm_automation_schedule.health_probe[0].name
      identity      = local.s.automation.identity
    } : null
    ml = local.s.ml.enabled ? {
      workspace_id = azurerm_machine_learning_workspace.this[0].id
      cluster_id   = azurerm_machine_learning_compute_cluster.cpu[0].id
      cluster_name = azurerm_machine_learning_compute_cluster.cpu[0].name
    } : null
    avs = { status = "blocked" }
    capabilities = {
      confidential_vm = local.s.confidential_vm.enabled ? "implemented" : "disabled"
      dedicated_host  = local.s.dedicated_host.enabled ? "implemented" : "disabled"
      gpu_vm          = local.s.gpu_vm.enabled ? "implemented" : "disabled"
      automation      = local.s.automation.enabled ? "implemented" : "disabled"
      ml              = local.s.ml.enabled ? "implemented" : "disabled"
      avs             = "blocked"
    }
  }
}
