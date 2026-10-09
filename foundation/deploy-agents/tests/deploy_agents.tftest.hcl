mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-agents-dev-sec" }
  }
  mock_resource "azurerm_dev_center" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DevCenter/devcenters/dc" }
  }
  mock_resource "azurerm_dev_center_project" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DevCenter/projects/p" }
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
  foundation_network = {
    spoke_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke"
    subnets = {
      "deploy-agents" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/deploy-agents", delegation = null }
    }
  }
  foundation_identity = {
    identities = {
      "deploy-agent" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/deploy-agent"
        client_id    = "22222222-2222-2222-2222-222222222222"
        principal_id = "11111111-1111-1111-1111-111111111111"
      }
    }
  }
  settings = {
    vmss = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvKebRa7TMkcMBo5kg1aEQCBT2UnIHtzs6LOrQJyNef test-fixture-private-key-discarded" }
  }
}

run "vmss_default" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.agents[0].overprovision == false && azurerm_linux_virtual_machine_scale_set.agents[0].upgrade_mode == "Manual" && azurerm_linux_virtual_machine_scale_set.agents[0].single_placement_group == true
    error_message = "Azure DevOps scale-set agent requirements: no overprovisioning, Manual upgrade policy"
  }
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.agents[0].instances == 0 && azurerm_linux_virtual_machine_scale_set.agents[0].disable_password_authentication
    error_message = "start at 0 instances, no passwords"
  }
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.agents[0].source_image_reference[0].offer == "ubuntu-24_04-lts"
    error_message = "Ubuntu 24.04 image expected"
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine_scale_set.agents[0].network_interface[0].ip_configuration[0].public_ip_address) == 0
    error_message = "agents must not have public IPs"
  }
  assert {
    condition     = contains(azurerm_linux_virtual_machine_scale_set.agents[0].identity[0].identity_ids, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/deploy-agent")
    error_message = "deploy-agent managed identity expected"
  }
  assert {
    condition     = length(azurerm_managed_devops_pool.this) == 0 && length(azurerm_dev_center.this) == 0
    error_message = "MDP is optional"
  }
}

run "managed_devops_pool" {
  command = plan
  variables {
    foundation_network = {
      spoke_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke"
      subnets = {
        "deploy-agents" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/deploy-agents", delegation = "Microsoft.DevOpsInfrastructure/pools" }
      }
    }
    settings = {
      mode = "managed-devops-pool"
      managed_devops_pool = {
        organization_url                   = "https://dev.azure.com/contoso"
        projects                           = ["enterprise-hello"]
        devops_infrastructure_principal_id = "33333333-3333-3333-3333-333333333333"
      }
    }
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine_scale_set.agents) == 0 && length(azurerm_managed_devops_pool.this) == 1
    error_message = "MDP replaces VMSS"
  }
  assert {
    condition     = azurerm_managed_devops_pool.this[0].virtual_machine_scale_set_fabric[0].subnet_id == var.foundation_network.subnets["deploy-agents"].id
    error_message = "MDP injected into deploy-agents subnet"
  }
  assert {
    condition     = azurerm_role_assignment.mdp_vnet_network_contributor[0].role_definition_name == "Network Contributor" && azurerm_role_assignment.mdp_vnet_reader[0].scope == var.foundation_network.spoke_vnet_id
    error_message = "DevOpsInfrastructure principal needs Reader + Network Contributor on the VNet"
  }
}

run "mdp_requires_delegated_subnet" {
  command = plan
  variables {
    settings = {
      mode = "managed-devops-pool"
      managed_devops_pool = {
        organization_url                   = "https://dev.azure.com/contoso"
        devops_infrastructure_principal_id = "33333333-3333-3333-3333-333333333333"
      }
    }
  }
  expect_failures = [azurerm_managed_devops_pool.this[0]]
}

run "vmss_requires_ssh_key" {
  command = plan
  variables {
    settings = {}
  }
  expect_failures = [var.settings]
}
