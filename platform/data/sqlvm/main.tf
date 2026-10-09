locals {
  component   = "platform-db-sqlvm"
  workload    = "data-sqlvm"
  identities  = var.foundation_identity.identities
  admin_login = "ehsqladmin"
  vm_name     = substr(module.naming.names.virtual_machine, 0, 64)
  # Windows computer names are limited to 15 characters.
  computer_name = substr(replace("${var.environment.name_prefix}sqlvm${var.environment.name}", "-", ""), 0, 15)
}

# Passwords come from Delinea DSV (sqlvm-admin-password, sqlvm-dbadapter-password) as pipeline inputs
# (var.admin_password / var.dbadapter_password). azurerm_windows_virtual_machine.admin_password,
# azurerm_mssql_virtual_machine.sql_connectivity_update_password and run-command protected parameters have no
# write-only variants, so the values are stored in Terraform state (encrypted, RBAC-restricted - ADR-0001 §4).
# Quotes are not allowed in the values (T-SQL safety, validated).

module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = local.workload
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = local.component
  layer       = "platform"
  domain      = "data"
  tier        = "database"
}

resource "azurerm_resource_group" "this" {
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags
}

resource "azurerm_network_interface" "this" {
  name                = "${module.naming.names.virtual_machine}-nic"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = module.tags.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.foundation_network.subnets["compute"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_151:encryption at host needs the EncryptionAtHost subscription feature; disks use platform-managed SSE (README)
  #checkov:skip=CKV_AZURE_50:VM extensions (Datadog Agent, Fluent Bit) are owned by observability (ADR-0001 §3 rule 3)
  name                       = local.vm_name
  computer_name              = local.computer_name
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  size                       = var.settings.vm_size
  admin_username             = local.admin_login
  admin_password             = var.admin_password
  network_interface_ids      = [azurerm_network_interface.this.id]
  patch_mode                 = "AutomaticByPlatform"
  patch_assessment_mode      = "AutomaticByPlatform"
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = false
  allow_extension_operations = true # observability installs the Datadog Agent / Fluent Bit extensions
  provision_vm_agent         = true
  tags                       = merge(module.tags.tags, { service = "hello-dbadapter" })

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.settings.os_disk_type
  }

  source_image_reference {
    publisher = var.settings.image.publisher
    offer     = var.settings.image.offer
    sku       = var.settings.image.sku
    version   = var.settings.image.version
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {} # managed storage account
}

resource "azurerm_managed_disk" "data" {
  #checkov:skip=CKV_AZURE_93:lab: platform-managed keys; disk encryption sets out of scope
  for_each                      = { data = var.settings.data_disk_gb, log = var.settings.log_disk_gb }
  name                          = "${local.vm_name}-${each.key}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  storage_account_type          = var.settings.data_disk_type
  create_option                 = "Empty"
  disk_size_gb                  = each.value
  network_access_policy         = "DenyAll"
  public_network_access_enabled = false
  tags                          = module.tags.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each           = { data = 0, log = 1 }
  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  lun                = each.value
  caching            = each.key == "data" ? "ReadOnly" : "None"
}

# SQL IaaS Agent extension registration (management modes were removed in March 2023: registration is
# least-privilege and features install the agent on demand). Private connectivity only.
resource "azurerm_mssql_virtual_machine" "this" {
  virtual_machine_id               = azurerm_windows_virtual_machine.this.id
  sql_license_type                 = "PAYG" # Developer edition images must use PAYG (no license charge)
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_port            = 1433
  sql_connectivity_update_username = local.admin_login
  sql_connectivity_update_password = var.admin_password
  tags                             = module.tags.tags

  storage_configuration {
    disk_type             = "NEW"
    storage_workload_type = "GENERAL"
    data_settings {
      default_file_path = "F:\\data"
      luns              = [0]
    }
    log_settings {
      default_file_path = "G:\\log"
      luns              = [1]
    }
  }

  auto_patching {
    day_of_week                            = "Sunday"
    maintenance_window_duration_in_minutes = 60
    maintenance_window_starting_hour       = 2
  }

  depends_on = [azurerm_virtual_machine_data_disk_attachment.data]
}

resource "azurerm_virtual_machine_run_command" "init_adapter_db" {
  name               = "init-adapter-db"
  location           = azurerm_resource_group.this.location
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  tags               = module.tags.tags

  source {
    script = file("${path.module}/scripts/init-adapter-db.ps1")
  }

  parameter {
    name  = "AdminLogin"
    value = local.admin_login
  }
  protected_parameter {
    name  = "AdminPassword"
    value = var.admin_password
  }
  protected_parameter {
    name  = "AdapterPassword"
    value = var.dbadapter_password
  }

  depends_on = [azurerm_mssql_virtual_machine.this]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  count                 = var.settings.auto_shutdown.enabled ? 1 : 0
  virtual_machine_id    = azurerm_windows_virtual_machine.this.id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = var.settings.auto_shutdown.time
  timezone              = var.settings.auto_shutdown.timezone
  tags                  = module.tags.tags

  notification_settings {
    enabled = false
  }
}
