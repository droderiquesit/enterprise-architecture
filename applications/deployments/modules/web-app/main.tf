# One App Service web app (Linux or Windows; code or container) with user-assigned identity, Key Vault reference
# identity, VNet integration, health check, private endpoint or deny-by-default access restrictions, and an
# optional `staging` slot for swap-based rollback. Logs: diagnostic settings (obs-diagnostics) - no sidecar.
locals {
  linux       = var.os_type == "Linux"
  container   = var.mode == "container"
  slots_ok    = can(regex("^(S[1-3]|P[0-9]+m?v[2-4]|I[1-6]v2)$", var.service_plan.sku))
  slot        = var.staging_slot && local.slots_ok
  private     = var.private_endpoint != null
  image_parts = local.container ? regex("^([^/]+)/(.+)$", var.image) : ["", ""]
  registry    = local.container ? "https://${local.image_parts[0]}" : null
  image_name  = local.container ? local.image_parts[1] : null

  settings = merge(var.app_settings, local.container ? {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    } : {}, local.linux && local.container ? {
    WEBSITES_PORT = lookup(var.app_settings, "PORT", "8080")
  } : {})
}

resource "azurerm_linux_web_app" "this" {
  #checkov:skip=CKV_AZURE_88:No Azure Files content storage is used (code runs from package / container image).
  #checkov:skip=CKV_AZURE_17:Client certificates are not used; access is network-restricted (private endpoint / deny-by-default).
  #checkov:skip=CKV_AZURE_13:App Service authentication is not used; services authenticate callers themselves (BFF Entra mode) and are private.
  #checkov:skip=CKV_AZURE_222:Public access is disabled whenever a private endpoint is configured (variable-driven).
  #checkov:skip=CKV_AZURE_71:User-assigned managed identity is configured (checkov only detects system-assigned).
  count                                          = local.linux ? 1 : 0
  name                                           = var.name
  resource_group_name                            = var.resource_group_name
  location                                       = var.location
  service_plan_id                                = var.service_plan.id
  tags                                           = var.tags
  https_only                                     = true
  public_network_access_enabled                  = !local.private
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = var.identity.id
  virtual_network_subnet_id                      = var.integration_subnet_id
  app_settings                                   = local.settings

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  logs {
    detailed_error_messages = false
    failed_request_tracing  = false
    http_logs {
      file_system {
        retention_in_days = 3
        retention_in_mb   = 35
      }
    }
  }

  site_config {
    always_on                                     = var.always_on
    http2_enabled                                 = true
    minimum_tls_version                           = "1.2"
    ftps_state                                    = "Disabled"
    vnet_route_all_enabled                        = var.integration_subnet_id != null
    health_check_path                             = var.health_check_path
    health_check_eviction_time_in_min             = 5
    app_command_line                              = var.startup_command
    container_registry_use_managed_identity       = local.container
    container_registry_managed_identity_client_id = local.container ? var.identity.client_id : null
    ip_restriction_default_action                 = local.private ? null : "Deny"

    application_stack {
      docker_image_name   = local.image_name
      docker_registry_url = local.registry
      python_version      = local.container ? null : var.stack.python_version
      dotnet_version      = local.container ? null : var.stack.dotnet_version
    }

    dynamic "ip_restriction" {
      for_each = local.private ? [] : var.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }
}

resource "azurerm_windows_web_app" "this" {
  #checkov:skip=CKV_AZURE_88:No Azure Files content storage is used (code runs from package / container image).
  #checkov:skip=CKV_AZURE_17:Client certificates are not used; access is network-restricted (private endpoint / deny-by-default).
  #checkov:skip=CKV_AZURE_13:App Service authentication is not used; services are private.
  #checkov:skip=CKV_AZURE_222:Public access is disabled whenever a private endpoint is configured (variable-driven).
  #checkov:skip=CKV_AZURE_71:User-assigned managed identity is configured (checkov only detects system-assigned).
  count                                          = local.linux ? 0 : 1
  name                                           = var.name
  resource_group_name                            = var.resource_group_name
  location                                       = var.location
  service_plan_id                                = var.service_plan.id
  tags                                           = var.tags
  https_only                                     = true
  public_network_access_enabled                  = !local.private
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = var.identity.id
  virtual_network_subnet_id                      = var.integration_subnet_id
  app_settings                                   = local.settings

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  logs {
    detailed_error_messages = false
    failed_request_tracing  = false
    http_logs {
      file_system {
        retention_in_days = 3
        retention_in_mb   = 35
      }
    }
  }

  site_config {
    always_on                                     = var.always_on
    http2_enabled                                 = true
    minimum_tls_version                           = "1.2"
    ftps_state                                    = "Disabled"
    use_32_bit_worker                             = false
    vnet_route_all_enabled                        = var.integration_subnet_id != null
    health_check_path                             = var.health_check_path
    health_check_eviction_time_in_min             = 5
    container_registry_use_managed_identity       = local.container
    container_registry_managed_identity_client_id = local.container ? var.identity.client_id : null
    ip_restriction_default_action                 = local.private ? null : "Deny"

    application_stack {
      current_stack       = local.container ? null : "dotnet"
      dotnet_version      = local.container ? null : var.stack.dotnet_version
      docker_image_name   = local.image_name
      docker_registry_url = local.registry
    }

    dynamic "ip_restriction" {
      for_each = local.private ? [] : var.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }
}

locals {
  app_id   = local.linux ? azurerm_linux_web_app.this[0].id : azurerm_windows_web_app.this[0].id
  hostname = local.linux ? azurerm_linux_web_app.this[0].default_hostname : azurerm_windows_web_app.this[0].default_hostname
}

# Staging slot: same settings; the pipeline deploys here, smoke-tests it, then swaps (rollback = swap back).
resource "azurerm_linux_web_app_slot" "staging" {
  #checkov:skip=CKV_AZURE_17:See production app.
  #checkov:skip=CKV_AZURE_13:See production app.
  #checkov:skip=CKV_AZURE_222:See production app.
  #checkov:skip=CKV_AZURE_71:User-assigned managed identity is configured.
  #checkov:skip=CKV_AZURE_88:No Azure Files content storage.
  count                                          = local.linux && local.slot ? 1 : 0
  name                                           = "staging"
  app_service_id                                 = local.app_id
  tags                                           = var.tags
  https_only                                     = true
  public_network_access_enabled                  = !local.private
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = var.identity.id
  virtual_network_subnet_id                      = var.integration_subnet_id
  app_settings                                   = local.settings

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  site_config {
    always_on                                     = false
    http2_enabled                                 = true
    minimum_tls_version                           = "1.2"
    ftps_state                                    = "Disabled"
    vnet_route_all_enabled                        = var.integration_subnet_id != null
    health_check_path                             = var.health_check_path
    health_check_eviction_time_in_min             = 5
    app_command_line                              = var.startup_command
    container_registry_use_managed_identity       = local.container
    container_registry_managed_identity_client_id = local.container ? var.identity.client_id : null
    ip_restriction_default_action                 = local.private ? null : "Deny"
    application_stack {
      docker_image_name   = local.image_name
      docker_registry_url = local.registry
      python_version      = local.container ? null : var.stack.python_version
      dotnet_version      = local.container ? null : var.stack.dotnet_version
    }
  }
}

resource "azurerm_windows_web_app_slot" "staging" {
  #checkov:skip=CKV_AZURE_17:See production app.
  #checkov:skip=CKV_AZURE_13:See production app.
  #checkov:skip=CKV_AZURE_222:See production app.
  #checkov:skip=CKV_AZURE_71:User-assigned managed identity is configured.
  #checkov:skip=CKV_AZURE_88:No Azure Files content storage.
  count                                          = !local.linux && local.slot ? 1 : 0
  name                                           = "staging"
  app_service_id                                 = local.app_id
  tags                                           = var.tags
  https_only                                     = true
  public_network_access_enabled                  = !local.private
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = var.identity.id
  virtual_network_subnet_id                      = var.integration_subnet_id
  app_settings                                   = local.settings

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  site_config {
    always_on                                     = false
    http2_enabled                                 = true
    minimum_tls_version                           = "1.2"
    ftps_state                                    = "Disabled"
    use_32_bit_worker                             = false
    vnet_route_all_enabled                        = var.integration_subnet_id != null
    health_check_path                             = var.health_check_path
    health_check_eviction_time_in_min             = 5
    container_registry_use_managed_identity       = local.container
    container_registry_managed_identity_client_id = local.container ? var.identity.client_id : null
    ip_restriction_default_action                 = local.private ? null : "Deny"
    application_stack {
      current_stack       = local.container ? null : "dotnet"
      dotnet_version      = local.container ? null : var.stack.dotnet_version
      docker_image_name   = local.image_name
      docker_registry_url = local.registry
    }
  }
}

module "private_endpoint" {
  source = "../../../../foundation/modules/private-endpoint"
  count  = local.private ? 1 : 0

  name                 = "${var.name}-pep"
  resource_group_name  = var.resource_group_name
  location             = var.location
  subnet_id            = var.private_endpoint.subnet_id
  target_resource_id   = local.app_id
  subresource_names    = ["sites"]
  private_dns_zone_ids = var.private_endpoint.dns_zone_id == null ? [] : [var.private_endpoint.dns_zone_id]
  tags                 = var.tags
}
