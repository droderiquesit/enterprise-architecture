resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  identities = var.foundation_identity.identities
  subnet_id  = local.subnets["compute"].id
  ssh_key    = var.settings.admin_ssh_public_key
  flex       = var.settings.flexible
  uni        = var.settings.uniform

  scale_sets = merge(
    local.flex.enabled ? { flexible = merge(local.flex, { id = azurerm_orchestrated_virtual_machine_scale_set.flexible[0].id }) } : {},
    local.uni.enabled ? { uniform = merge(local.uni, { id = azurerm_linux_virtual_machine_scale_set.uniform[0].id }) } : {},
  )
}

module "baseline" {
  source    = "../../modules/compute-linux-baseline"
  component = "platform-vmss"
}

resource "random_password" "admin" {
  count            = local.ssh_key == null ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# ---------------------------------------------------------------- Flexible orchestration
resource "azurerm_orchestrated_virtual_machine_scale_set" "flexible" {
  count = local.flex.enabled ? 1 : 0

  name                         = "${local.names.vm_scale_set}-flex"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = local.location
  sku_name                     = local.flex.sku
  instances                    = local.flex.instances
  platform_fault_domain_count  = 1
  zones                        = length(local.flex.zones) > 0 ? local.flex.zones : null
  encryption_at_host_enabled   = var.settings.encryption_at_host_enabled
  extension_operations_enabled = true # observability adds Datadog Agent + Fluent Bit extensions
  user_data_base64             = null
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identities[local.flex.identity].id]
  }

  os_profile {
    custom_data = module.baseline.custom_data
    linux_configuration {
      admin_username                  = var.settings.admin_username
      admin_password                  = local.ssh_key == null ? random_password.admin[0].result : null
      disable_password_authentication = local.ssh_key != null
      computer_name_prefix            = "vmss-worker"
      patch_mode                      = "AutomaticByPlatform"
      patch_assessment_mode           = "AutomaticByPlatform"
      provision_vm_agent              = true
      dynamic "admin_ssh_key" {
        for_each = local.ssh_key == null ? [] : [local.ssh_key]
        content {
          username   = var.settings.admin_username
          public_key = admin_ssh_key.value
        }
      }
    }
  }

  network_interface {
    name    = "nic"
    primary = true
    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = local.subnet_id
      # no public_ip_address block: instances are private
    }
  }

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

  boot_diagnostics {}

  lifecycle {
    # instance count is owned by autoscale; extensions are owned by observability.
    ignore_changes = [instances, extension, os_profile[0].custom_data]
  }
}

# ---------------------------------------------------------------- Uniform orchestration
# upgrade_mode = "Manual": there is no load balancer/health probe for this internal adapter and
# the app is installed after the platform (run command), so a Rolling policy would gate every
# platform model change on an app health signal the platform does not own. The deployment root
# performs batch-wise rolling reinstalls via run command and applies model updates per instance
# (`az vmss update-instances`), which keeps rollouts controlled without coupling the layers.
resource "azurerm_linux_virtual_machine_scale_set" "uniform" {
  #checkov:skip=CKV_AZURE_97:encryption_at_host_enabled is a setting (needs the EncryptionAtHost feature registration).
  count = local.uni.enabled ? 1 : 0
  #checkov:skip=CKV_AZURE_49:SSH key auth when admin_ssh_public_key is set; otherwise a random break-glass password kept only in state.
  #checkov:skip=CKV_AZURE_149:See CKV_AZURE_49.

  name                            = "${local.names.vm_scale_set}-uni"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = local.location
  sku                             = local.uni.sku
  instances                       = local.uni.instances
  zones                           = length(local.uni.zones) > 0 ? local.uni.zones : null
  admin_username                  = var.settings.admin_username
  admin_password                  = local.ssh_key == null ? random_password.admin[0].result : null
  disable_password_authentication = local.ssh_key != null
  computer_name_prefix            = "vmss-dbad"
  custom_data                     = module.baseline.custom_data
  upgrade_mode                    = "Manual"
  overprovision                   = false
  single_placement_group          = false
  provision_vm_agent              = true
  extension_operations_enabled    = true
  encryption_at_host_enabled      = var.settings.encryption_at_host_enabled
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = local.tags

  dynamic "admin_ssh_key" {
    for_each = local.ssh_key == null ? [] : [local.ssh_key]
    content {
      username   = var.settings.admin_username
      public_key = admin_ssh_key.value
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identities[local.uni.identity].id]
  }

  network_interface {
    name    = "nic"
    primary = true
    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = local.subnet_id
    }
  }

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

  boot_diagnostics {}

  lifecycle {
    ignore_changes = [instances, extension, custom_data]
  }
}

# ---------------------------------------------------------------- autoscale (ceilings)
resource "azurerm_monitor_autoscale_setting" "this" {
  for_each = var.settings.autoscale.enabled ? local.scale_sets : {}

  name                = "${local.names.vm_scale_set}-${each.key}-autoscale"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  target_resource_id  = each.value.id
  enabled             = true
  tags                = local.tags

  profile {
    name = "default"
    capacity {
      default = each.value.instances
      minimum = each.value.min_instances
      maximum = each.value.max_instances
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_namespace   = "microsoft.compute/virtualmachinescalesets"
        metric_resource_id = each.value.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.settings.autoscale.scale_out_cpu
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_namespace   = "microsoft.compute/virtualmachinescalesets"
        metric_resource_id = each.value.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.settings.autoscale.scale_in_cpu
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT10M"
      }
    }
  }

  dynamic "notification" {
    for_each = length(var.settings.autoscale.notification_email) > 0 ? [1] : []
    content {
      email {
        custom_emails = var.settings.autoscale.notification_email
      }
    }
  }
}
