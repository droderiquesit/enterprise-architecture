locals {
  s          = var.settings
  identities = var.foundation_identity.identities
  subnet_id  = local.subnets["compute"].id
  any        = local.s.confidential_vm.enabled || local.s.dedicated_host.enabled || local.s.gpu_vm.enabled || local.s.automation.enabled || local.s.ml.enabled
  ssh_key    = local.s.admin_ssh_public_key

  # Linux VMs this root may create (all optional).
  vms = merge(
    local.s.confidential_vm.enabled ? {
      cvm = {
        size                     = local.s.confidential_vm.size, identity = local.s.confidential_vm.identity
        offer                    = local.s.confidential_vm.image_offer, sku = local.s.confidential_vm.image_sku
        security_encryption_type = local.s.confidential_vm.security_encryption_type, host = false
      }
    } : {},
    local.s.dedicated_host.enabled ? {
      dh = {
        size  = local.s.dedicated_host.vm_size, identity = local.s.dedicated_host.identity
        offer = "ubuntu-24_04-lts", sku = "server", security_encryption_type = null, host = true
      }
    } : {},
    local.s.gpu_vm.enabled ? {
      gpu = {
        size  = local.s.gpu_vm.size, identity = local.s.gpu_vm.identity
        offer = "ubuntu-24_04-lts", sku = "server", security_encryption_type = null, host = false
      }
    } : {},
  )
}

resource "azurerm_resource_group" "this" {
  count    = local.any ? 1 : 0
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

module "baseline" {
  source    = "../../modules/compute-linux-baseline"
  component = "platform-specialized-compute"
}

resource "random_password" "admin" {
  count            = length(local.vms) > 0 && local.ssh_key == null ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# ---------------------------------------------------------------- dedicated host
resource "azurerm_dedicated_host_group" "this" {
  count                       = local.s.dedicated_host.enabled ? 1 : 0
  name                        = local.names.dedicated_host_group
  resource_group_name         = azurerm_resource_group.this[0].name
  location                    = local.location
  platform_fault_domain_count = 1
  automatic_placement_enabled = true
  tags                        = local.tags
}

resource "azurerm_dedicated_host" "this" {
  count                   = local.s.dedicated_host.enabled ? 1 : 0
  name                    = "${local.names.dedicated_host_group}-host0"
  location                = local.location
  dedicated_host_group_id = azurerm_dedicated_host_group.this[0].id
  sku_name                = local.s.dedicated_host.host_sku
  platform_fault_domain   = 0
  auto_replace_on_failure = true
  tags                    = local.tags
}

# ---------------------------------------------------------------- Linux VMs (cvm / dh / gpu)
resource "azurerm_network_interface" "this" {
  for_each            = local.vms
  name                = "${local.names.virtual_machine}-${each.key}-nic"
  resource_group_name = azurerm_resource_group.this[0].name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_50:Extension operations stay enabled for observability agents (ADR-0001 §3).
  for_each = local.vms
  #checkov:skip=CKV_AZURE_178:SSH key auth when admin_ssh_public_key is set; otherwise random break-glass password (state only).
  #checkov:skip=CKV_AZURE_149:See CKV_AZURE_178.

  name                            = "${local.names.virtual_machine}-${each.key}"
  computer_name                   = "vm-hello-${each.key}"
  resource_group_name             = azurerm_resource_group.this[0].name
  location                        = local.location
  size                            = each.value.size
  network_interface_ids           = [azurerm_network_interface.this[each.key].id]
  admin_username                  = local.s.admin_username
  admin_password                  = local.ssh_key == null ? random_password.admin[0].result : null
  disable_password_authentication = local.ssh_key != null
  custom_data                     = module.baseline.custom_data
  dedicated_host_id               = each.value.host ? azurerm_dedicated_host.this[0].id : null
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  patch_mode                      = "AutomaticByPlatform"
  patch_assessment_mode           = "AutomaticByPlatform"
  allow_extension_operations      = true
  provision_vm_agent              = true
  tags                            = local.tags

  dynamic "admin_ssh_key" {
    for_each = local.ssh_key == null ? [] : [local.ssh_key]
    content {
      username   = local.s.admin_username
      public_key = admin_ssh_key.value
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identities[each.value.identity].id]
  }

  os_disk {
    caching                  = "ReadWrite"
    storage_account_type     = "StandardSSD_LRS"
    security_encryption_type = each.value.security_encryption_type
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = each.value.offer
    sku       = each.value.sku
    version   = "latest"
  }

  boot_diagnostics {}

  lifecycle {
    ignore_changes = [custom_data]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  for_each              = local.vms
  virtual_machine_id    = azurerm_linux_virtual_machine.this[each.key].id
  location              = local.location
  enabled               = true
  daily_recurrence_time = local.s.auto_shutdown_time
  timezone              = "UTC"
  tags                  = local.tags
  notification_settings {
    enabled = false
  }
}

# ---------------------------------------------------------------- Automation
resource "azurerm_automation_account" "this" {
  count                         = local.s.automation.enabled ? 1 : 0
  name                          = local.names.automation
  resource_group_name           = azurerm_resource_group.this[0].name
  location                      = local.location
  sku_name                      = "Basic"
  local_authentication_enabled  = false
  public_network_access_enabled = false # cloud jobs still run; webhooks/hybrid workers need Private Link
  tags                          = local.tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [local.identities[local.s.automation.identity].id]
  }
}

# Placeholder schedule; the deployment root links its runbook to it (job schedule).
resource "azurerm_automation_schedule" "health_probe" {
  count                   = local.s.automation.enabled ? 1 : 0
  name                    = "hello-health-probe"
  resource_group_name     = azurerm_resource_group.this[0].name
  automation_account_name = azurerm_automation_account.this[0].name
  frequency               = "Hour"
  interval                = local.s.automation.schedule_interval
  timezone                = "Etc/UTC"
  description             = "Placeholder: applications/deployments/specialized links the python3 health-probe runbook."
}

# ---------------------------------------------------------------- Machine Learning
# The workspace REQUIRES Application Insights, Key Vault and a storage account (azurerm marks
# application_insights_id/key_vault_id/storage_account_id as required). They are platform-required
# dependencies of the workspace, not observability resources; diagnostic settings stay with obs.
resource "azurerm_log_analytics_workspace" "ml" {
  count                        = local.s.ml.enabled ? 1 : 0
  name                         = "${local.names.log_analytics}-ml"
  resource_group_name          = azurerm_resource_group.this[0].name
  location                     = local.location
  sku                          = "PerGB2018"
  retention_in_days            = 30
  daily_quota_gb               = 0.5
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_application_insights" "ml" {
  count                        = local.s.ml.enabled ? 1 : 0
  name                         = "${local.names.ml_workspace}-appi"
  resource_group_name          = azurerm_resource_group.this[0].name
  location                     = local.location
  application_type             = "other"
  workspace_id                 = azurerm_log_analytics_workspace.ml[0].id
  local_authentication_enabled = false
  daily_data_cap_in_gb         = 0.5
  tags                         = local.tags
}

# Required by azurerm_machine_learning_workspace (key_vault_id is a required argument): the workspace's own internal
# store, off by default (settings.ml.enabled), holding NO lab secrets (all lab secrets live in Delinea DSV,
# ADR-0001 section 14).
# ownership:allow OWN008 Azure ML workspace dependency, not a secret store of the lab
resource "azurerm_key_vault" "ml" {
  #checkov:skip=CKV_AZURE_189:AML workspace without workspace private endpoints: public endpoint with network ACL Deny + AzureServices bypass; RBAC-only.
  count                         = local.s.ml.enabled ? 1 : 0
  name                          = substr("${var.environment.name_prefix}-kv-ml-${var.environment.name}-${module.naming.suffix}", 0, 24)
  resource_group_name           = azurerm_resource_group.this[0].name
  location                      = local.location
  tenant_id                     = var.environment.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = true # AML control plane reaches it as a trusted service; data-plane denied below
  tags                          = local.tags
  #checkov:skip=CKV2_AZURE_32:AML workspace key vault in a lab without workspace private endpoints; network ACL default Deny + AzureServices bypass.

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

module "ml_storage" {
  count  = local.s.ml.enabled ? 1 : 0
  source = "../../modules/compute-runtime-storage"

  name                          = substr("${local.unique.storage}ml", 0, 24)
  resource_group_name           = azurerm_resource_group.this[0].name
  location                      = local.location
  public_network_access_enabled = true # AML managed network reaches it via managed private endpoints; Entra-only
  tags                          = local.tags
}

resource "azurerm_machine_learning_workspace" "this" {
  #checkov:skip=CKV_AZURE_144:Optional lab workspace without private endpoints (Entra ID auth); compute runs in the managed network without public IPs.
  #checkov:skip=CKV2_AZURE_49:See CKV_AZURE_144; enable workspace Private Link when the specialized profile needs it.
  count                         = local.s.ml.enabled ? 1 : 0
  name                          = local.names.ml_workspace
  resource_group_name           = azurerm_resource_group.this[0].name
  location                      = local.location
  application_insights_id       = azurerm_application_insights.ml[0].id
  key_vault_id                  = azurerm_key_vault.ml[0].id
  storage_account_id            = module.ml_storage[0].id
  storage_account_access_type   = "Identity" # shared keys are disabled on the default store
  public_network_access_enabled = true
  v1_legacy_mode_enabled        = false
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  managed_network {
    isolation_mode = "AllowInternetOutbound"
  }
}

resource "azurerm_machine_learning_compute_cluster" "cpu" {
  count                         = local.s.ml.enabled ? 1 : 0
  name                          = "cpu-cluster"
  location                      = local.location
  machine_learning_workspace_id = azurerm_machine_learning_workspace.this[0].id
  vm_size                       = local.s.ml.cluster_vm_size
  vm_priority                   = local.s.ml.cluster_priority
  node_public_ip_enabled        = false # workspace managed network
  local_auth_enabled            = false
  ssh_public_access_enabled     = false
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  scale_settings {
    min_node_count                       = 0
    max_node_count                       = local.s.ml.cluster_max
    scale_down_nodes_after_idle_duration = "PT10M"
  }
}
