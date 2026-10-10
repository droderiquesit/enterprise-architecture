module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "agents"
}

module "tags" {
  source      = "../modules/tags"
  environment = var.environment
  component   = "foundation-deploy-agents"
  layer       = "foundation"
  domain      = "delivery"
}

locals {
  names     = module.naming.names
  tags      = module.tags.tags
  location  = var.environment.location
  subnet    = var.foundation_network.subnets["deploy-agents"]
  identity  = var.foundation_identity.identities["deploy-agent"]
  vmss_mode = var.settings.mode == "vmss"
  mdp_mode  = var.settings.mode == "managed-devops-pool"
  vmss      = var.settings.vmss
  mdp       = var.settings.managed_devops_pool
}

resource "azurerm_resource_group" "agents" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# ------------------------------------------------------------------ VMSS agents (default)
# Requirements for Azure DevOps "Azure Virtual Machine Scale Set agents"
# (https://learn.microsoft.com/azure/devops/pipelines/agents/scale-set-agents):
#   Uniform orchestration, overprovisioning disabled, upgrade policy Manual, no autoscale, no instance protection.
# Azure DevOps owns capacity (instances) and installs the agent extension; both are ignored here.
resource "azurerm_linux_virtual_machine_scale_set" "agents" {
  #checkov:skip=CKV_AZURE_97:encryption at host is a setting (default off) because it requires the Microsoft.Compute/EncryptionAtHost feature registration per subscription.
  count = local.vmss_mode ? 1 : 0

  name                            = local.names.vm_scale_set
  resource_group_name             = azurerm_resource_group.agents.name
  location                        = local.location
  sku                             = local.vmss.sku
  instances                       = 0
  overprovision                   = false
  single_placement_group          = true # default single placement group (<= 100 agents), per scale-set docs
  upgrade_mode                    = "Manual"
  zones                           = local.vmss.zones
  admin_username                  = local.vmss.admin_username
  disable_password_authentication = true
  encryption_at_host_enabled      = local.vmss.encryption_at_host
  computer_name_prefix            = "${var.environment.name_prefix}agt"
  tags                            = local.tags

  admin_ssh_key {
    username   = local.vmss.admin_username
    public_key = local.vmss.admin_ssh_public_key
  }

  source_image_reference {
    publisher = local.vmss.image.publisher
    offer     = local.vmss.image.offer
    sku       = local.vmss.image.sku
    version   = local.vmss.image.version
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = local.vmss.os_disk_type
    disk_size_gb         = local.vmss.os_disk_size_gb
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = local.subnet.id
      # No public IP: egress via the subnet's NAT Gateway / firewall route (foundation-network).
    }
  }

  boot_diagnostics {} # managed storage account

  lifecycle {
    precondition {
      condition     = try(local.subnet.delegation, null) == null
      error_message = "VMSS agents need a non-delegated deploy-agents subnet (foundation-network settings.deploy_agents_mode = vmss)."
    }
    # Azure DevOps scales the set and adds its agent extension + __AzureDevOpsElasticPool tags.
    ignore_changes = [instances, extension, tags["__AzureDevOpsElasticPool"], tags["__AzureDevOpsElasticPoolTimeStamp"]]
  }
}

# ------------------------------------------------------------------ Managed DevOps Pools (optional)
# azurerm 5.9 ships azurerm_managed_devops_pool + azurerm_dev_center(_project): no AzAPI needed.
resource "azurerm_dev_center" "this" {
  count = local.mdp_mode || local.copilot_pool.enabled ? 1 : 0

  name                = local.names.dev_center
  resource_group_name = azurerm_resource_group.agents.name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_dev_center_project" "this" {
  count = local.mdp_mode || local.copilot_pool.enabled ? 1 : 0

  name                = "${local.names.dev_center}-pipelines"
  resource_group_name = azurerm_resource_group.agents.name
  location            = local.location
  dev_center_id       = azurerm_dev_center.this[0].id
  description         = "Enterprise Hello pipeline agents"
  tags                = local.tags
}

# The Managed DevOps Pools first-party principal ("DevOpsInfrastructure") needs Reader + Network Contributor
# on the VNet to inject agents (https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking).
resource "azurerm_role_assignment" "mdp_vnet_reader" {
  count = local.mdp_mode ? 1 : 0

  scope                = var.foundation_network.spoke_vnet_id
  role_definition_name = "Reader"
  principal_id         = local.mdp.devops_infrastructure_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "mdp_vnet_network_contributor" {
  count = local.mdp_mode ? 1 : 0

  scope                = var.foundation_network.spoke_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = local.mdp.devops_infrastructure_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_managed_devops_pool" "this" {
  count = local.mdp_mode ? 1 : 0

  name                  = local.names.devops_pool
  resource_group_name   = azurerm_resource_group.agents.name
  location              = local.location
  dev_center_project_id = azurerm_dev_center_project.this[0].id
  maximum_concurrency   = local.mdp.max_concurrency
  tags                  = local.tags

  azure_devops_organization {
    organization {
      url         = local.mdp.organization_url
      projects    = local.mdp.projects
      parallelism = local.mdp.parallelism
    }
    permission {
      kind = "CreatorOnly"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  stateless_agent {}

  virtual_machine_scale_set_fabric {
    sku_name  = local.mdp.sku_name
    subnet_id = local.subnet.id

    image {
      well_known_image_name = local.mdp.image_name
      buffer                = "*"
    }
  }

  depends_on = [azurerm_role_assignment.mdp_vnet_reader, azurerm_role_assignment.mdp_vnet_network_contributor]

  lifecycle {
    precondition {
      condition     = try(local.subnet.delegation, null) == "Microsoft.DevOpsInfrastructure/pools"
      error_message = "Managed DevOps Pools need deploy-agents delegated to Microsoft.DevOpsInfrastructure/pools (foundation-network settings.deploy_agents_mode = managed-devops-pool)."
    }
  }
}

# ------------------------------------------------------------- Copilot code review compute pool
locals {
  copilot_pool = var.settings.copilot_review_pool
}

resource "azurerm_managed_devops_pool" "copilot_review" {
  count = local.copilot_pool.enabled ? 1 : 0

  name                  = "${local.names.devops_pool}-copilot"
  resource_group_name   = azurerm_resource_group.agents.name
  location              = local.location
  dev_center_project_id = azurerm_dev_center_project.this[0].id
  maximum_concurrency   = local.copilot_pool.max_concurrency
  tags                  = merge(local.tags, { purpose = "github-copilot-code-review" })

  azure_devops_organization {
    organization {
      url         = local.copilot_pool.organization_url
      projects    = local.copilot_pool.projects
      parallelism = local.copilot_pool.max_concurrency
    }
    permission {
      kind = "CreatorOnly"
    }
  }

  stateless_agent {}

  # Microsoft-hosted networking (no subnet): Copilot reviews need no private network access.
  virtual_machine_scale_set_fabric {
    sku_name = local.copilot_pool.sku_name

    image {
      well_known_image_name = local.copilot_pool.image_name
      buffer                = "*"
    }
  }
}
