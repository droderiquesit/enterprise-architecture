resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  identities = var.foundation_identity.identities
  linux      = var.settings.linux_vm
  windows    = var.settings.windows_vm
  subnet_id  = local.subnets["compute"].id
  ssh_key    = local.linux.admin_ssh_public_key

  vms = merge(
    local.linux.enabled ? { linux = { os_type = "Linux", identity = local.linux.identity } } : {},
    local.windows.enabled ? { windows = { os_type = "Windows", identity = local.windows.identity } } : {},
  )
  vm_ids = merge(
    local.linux.enabled ? { linux = azurerm_linux_virtual_machine.this[0].id } : {},
    local.windows.enabled ? { windows = azurerm_windows_virtual_machine.this[0].id } : {},
  )
  login_roles = merge(
    { for p in var.settings.admin_login_principal_ids : "admin-${p}" => { principal_id = p, role = "Virtual Machine Administrator Login" } },
    { for p in var.settings.user_login_principal_ids : "user-${p}" => { principal_id = p, role = "Virtual Machine User Login" } },
  )
}

module "baseline" {
  source    = "../../modules/compute-linux-baseline"
  component = "platform-vm"
}

# Break-glass local credentials live only in (protected) state; day-to-day access is Entra ID login.
resource "random_password" "linux" {
  count            = local.linux.enabled && local.ssh_key == null ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "windows" {
  count            = local.windows.enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "this" {
  for_each = local.vms

  name                           = "${local.names.virtual_machine}-${each.key}-nic"
  resource_group_name            = azurerm_resource_group.this.name
  location                       = local.location
  accelerated_networking_enabled = false # Bsv2 2-vCPU sizes do not support it
  tags                           = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    # no public_ip_address_id: hosts are private; egress via foundation NAT/firewall
  }
}

# ---------------------------------------------------------------- Linux
resource "azurerm_linux_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_50:Extension operations must stay enabled: observability installs the Datadog Agent/Fluent Bit extensions and Entra ID login is an extension.
  count = local.linux.enabled ? 1 : 0
  #checkov:skip=CKV_AZURE_178:SSH key auth is used when admin_ssh_public_key is set; otherwise a random break-glass password (state only) - Entra ID SSH login is the access path.
  #checkov:skip=CKV_AZURE_149:See CKV_AZURE_178 justification (password only as break-glass fallback).

  name                       = "${local.names.virtual_machine}-lin"
  computer_name              = "vm-hello-lin"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = local.location
  size                       = local.linux.size
  zone                       = local.linux.zone
  network_interface_ids      = [azurerm_network_interface.this["linux"].id]
  admin_username             = local.linux.admin_username
  admin_password             = local.ssh_key == null ? random_password.linux[0].result : null
  custom_data                = module.baseline.custom_data
  provision_vm_agent         = true
  allow_extension_operations = true # observability installs Datadog Agent + Fluent Bit extensions
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.settings.encryption_at_host_enabled
  patch_mode                 = "AutomaticByPlatform"
  patch_assessment_mode      = "AutomaticByPlatform"
  tags                       = local.tags

  disable_password_authentication = local.ssh_key != null
  dynamic "admin_ssh_key" {
    for_each = local.ssh_key == null ? [] : [local.ssh_key]
    content {
      username   = local.linux.admin_username
      public_key = admin_ssh_key.value
    }
  }

  identity {
    type         = var.settings.entra_login_enabled ? "SystemAssigned, UserAssigned" : "UserAssigned"
    identity_ids = [local.identities[local.linux.identity].id]
  }

  os_disk {
    name                 = "${local.names.virtual_machine}-lin-osdisk"
    caching              = "ReadWrite"
    storage_account_type = local.linux.os_disk_type
  }

  source_image_reference {
    publisher = local.linux.image.publisher
    offer     = local.linux.image.offer
    sku       = local.linux.image.sku
    version   = local.linux.image.version
  }

  boot_diagnostics {} # managed storage account

  lifecycle {
    ignore_changes = [custom_data] # cloud-init runs once; changes must not recreate the host
  }
}

# ---------------------------------------------------------------- Windows
resource "azurerm_windows_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_151:encryption_at_host_enabled is a setting (needs the EncryptionAtHost feature registration); managed disks are encrypted at rest with platform keys.
  #checkov:skip=CKV_AZURE_50:Extension operations must stay enabled: observability installs the Datadog Agent/Fluent Bit extensions and Entra ID login is an extension.
  count = local.windows.enabled ? 1 : 0

  name                       = "${local.names.virtual_machine}-win"
  computer_name              = "vm-hello-win" # <= 15 chars
  resource_group_name        = azurerm_resource_group.this.name
  location                   = local.location
  size                       = local.windows.size
  zone                       = local.windows.zone
  network_interface_ids      = [azurerm_network_interface.this["windows"].id]
  admin_username             = local.windows.admin_username
  admin_password             = random_password.windows[0].result
  provision_vm_agent         = true
  allow_extension_operations = true
  automatic_updates_enabled  = true
  hotpatching_enabled        = local.windows.hotpatching
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.settings.encryption_at_host_enabled
  patch_mode                 = "AutomaticByPlatform"
  patch_assessment_mode      = "AutomaticByPlatform"
  timezone                   = "UTC"
  tags                       = local.tags

  identity {
    type         = var.settings.entra_login_enabled ? "SystemAssigned, UserAssigned" : "UserAssigned"
    identity_ids = [local.identities[local.windows.identity].id]
  }

  os_disk {
    name                 = "${local.names.virtual_machine}-win-osdisk"
    caching              = "ReadWrite"
    storage_account_type = local.windows.os_disk_type
  }

  source_image_reference {
    publisher = local.windows.image.publisher
    offer     = local.windows.image.offer
    sku       = local.windows.image.sku
    version   = local.windows.image.version
  }

  boot_diagnostics {}
}

# ---------------------------------------------------------------- Entra ID login (access)
resource "azurerm_virtual_machine_extension" "entra_login_linux" {
  count = local.linux.enabled && var.settings.entra_login_enabled ? 1 : 0

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.this[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = local.tags
}

resource "azurerm_virtual_machine_extension" "entra_login_windows" {
  count = local.windows.enabled && var.settings.entra_login_enabled ? 1 : 0

  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
  tags                       = local.tags
}

resource "azurerm_role_assignment" "login" {
  for_each = { for pair in setproduct(keys(local.vms), keys(local.login_roles)) : "${pair[0]}-${pair[1]}" => { vm = pair[0], grant = local.login_roles[pair[1]] } }

  scope                = local.vm_ids[each.value.vm]
  role_definition_name = each.value.grant.role
  principal_id         = each.value.grant.principal_id
}

# ---------------------------------------------------------------- cost control
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  for_each = var.settings.auto_shutdown.enabled ? local.vms : {}

  virtual_machine_id    = local.vm_ids[each.key]
  location              = local.location
  enabled               = true
  daily_recurrence_time = var.settings.auto_shutdown.time
  timezone              = var.settings.auto_shutdown.timezone
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
