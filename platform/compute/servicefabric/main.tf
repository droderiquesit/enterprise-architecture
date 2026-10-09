locals {
  enabled = var.settings.enabled
  nt      = var.settings.node_type
  byovnet = var.settings.sf_resource_provider_principal_id != null
}

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

resource "random_password" "admin" {
  count            = local.enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_role_assignment" "sfrp_subnet" {
  count                = local.enabled && local.byovnet ? 1 : 0
  scope                = local.subnets["sfmc"].id
  role_definition_name = "Network Contributor"
  principal_id         = var.settings.sf_resource_provider_principal_id
  description          = "Service Fabric Resource Provider: BYO VNet for the managed cluster"
}

resource "azurerm_service_fabric_managed_cluster" "this" {
  count = local.enabled ? 1 : 0

  name                   = local.names.service_fabric
  resource_group_name    = azurerm_resource_group.this[0].name
  location               = local.location
  sku                    = var.settings.sku
  dns_name               = local.names.service_fabric
  client_connection_port = 19000
  http_gateway_port      = 19080
  username               = "sfadmin"
  password               = random_password.admin[0].result
  subnet_id              = local.byovnet ? local.subnets["sfmc"].id : null
  upgrade_wave           = "Wave0"
  tags                   = local.tags

  authentication {
    dynamic "certificate" {
      for_each = var.settings.client_certificate_thumbprint == null ? [] : [1]
      content {
        thumbprint  = var.settings.client_certificate_thumbprint
        common_name = var.settings.client_certificate_common_name
        type        = "AdminClient"
      }
    }
    dynamic "active_directory" {
      for_each = var.settings.entra_cluster_application_id == null ? [] : [1]
      content {
        tenant_id              = var.environment.tenant_id
        cluster_application_id = var.settings.entra_cluster_application_id
        client_application_id  = var.settings.entra_client_application_id
      }
    }
  }

  lb_rule {
    frontend_port      = var.settings.app_port
    backend_port       = var.settings.app_port
    protocol           = "tcp"
    probe_protocol     = "http"
    probe_request_path = "/healthz"
  }

  node_type {
    name                   = local.nt.name
    primary                = true
    vm_size                = local.nt.vm_size
    vm_instance_count      = local.nt.instance_count
    vm_image_publisher     = "MicrosoftWindowsServer"
    vm_image_offer         = "WindowsServer"
    vm_image_sku           = local.nt.image_sku
    vm_image_version       = "latest"
    data_disk_size_gb      = local.nt.data_disk_size_gb
    data_disk_type         = local.nt.data_disk_type
    application_port_range = local.nt.application_ports
    ephemeral_port_range   = local.nt.ephemeral_ports
  }

  depends_on = [azurerm_role_assignment.sfrp_subnet]
}
