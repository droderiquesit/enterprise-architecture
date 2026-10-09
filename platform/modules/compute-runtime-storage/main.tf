# Hardened storage account for compute *runtimes* (Functions host/deployment storage, Durable
# Functions runtime state, Batch auto-storage, ML workspace storage). Identity-based access by
# default: shared keys off, no public blobs, TLS 1.2, optional private endpoints + RBAC grants.
# Shared code module (platform layer); ownership stays with the calling root (ADR-0001 §3 rule 1).
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.9" }
  }
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "storage account names are 3-24 lowercase alphanumerics."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "replication" {
  type    = string
  default = "LRS"
}

variable "shared_access_key_enabled" {
  type        = bool
  default     = false
  description = "Keep false unless a consumer cannot use Entra ID (documented per caller)."
}

variable "public_network_access_enabled" {
  type    = bool
  default = false
}

variable "network_bypass" {
  type    = list(string)
  default = ["AzureServices"]
}

variable "containers" {
  type    = list(string)
  default = []
}

variable "private_endpoints" {
  description = "Private Link sub-resources to expose (blob, queue, table, file, dfs)."
  type        = list(string)
  default     = []
}

variable "private_endpoint_subnet_id" {
  type    = string
  default = null
}

variable "private_endpoint_name_prefix" {
  type    = string
  default = "pep"
}

variable "private_dns_zone_ids" {
  description = "Map of sub-resource => private DNS zone id (missing keys => no zone group)."
  type        = map(string)
  default     = {}
}

variable "role_assignments" {
  description = "key => {principal_id, role, container (optional: scope to one container)}."
  type = map(object({
    principal_id = string
    role         = string
    container    = optional(string)
  }))
  default = {}
}

variable "blob_retention_days" {
  type    = number
  default = 7
}

resource "azurerm_storage_account" "this" {
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for synthetic lab data (no CMK).
  #checkov:skip=CKV_AZURE_206:Replication is a caller setting; LRS is the low-cost lab default.
  #checkov:skip=CKV2_AZURE_33:Private endpoints are created by this module when private_endpoints is set (caller decides per SKU/plan).
  #checkov:skip=CKV_AZURE_33:Queue service logging is a diagnostic setting owned by observability (ADR-0001 §3 rule 4).
  #checkov:skip=CKV2_AZURE_21:Blob service logging is a diagnostic setting owned by observability (ADR-0001 §3 rule 4).
  name                             = var.name
  resource_group_name              = var.resource_group_name
  location                         = var.location
  account_tier                     = "Standard"
  account_kind                     = "StorageV2"
  account_replication_type         = var.replication
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  shared_access_key_enabled        = var.shared_access_key_enabled
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  public_network_access            = var.public_network_access_enabled ? "Enabled" : "Disabled"
  local_user_enabled               = false
  sftp_enabled                     = false
  cross_tenant_replication_enabled = false
  tags                             = var.tags

  network_rules {
    default_action = var.public_network_access_enabled ? "Allow" : "Deny"
    bypass         = var.network_bypass
  }

  blob_properties {
    delete_retention_policy {
      days = var.blob_retention_days
    }
    container_delete_retention_policy {
      days = var.blob_retention_days
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }
}

resource "azurerm_storage_container" "this" {
  #checkov:skip=CKV2_AZURE_21:Blob logging is a diagnostic setting owned by observability.
  for_each              = toset(var.containers)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "this" {
  for_each = toset(var.private_endpoints)

  name                          = "${var.private_endpoint_name_prefix}-${var.name}-${each.value}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  subnet_id                     = var.private_endpoint_subnet_id
  custom_network_interface_name = "${var.private_endpoint_name_prefix}-${var.name}-${each.value}-nic"
  tags                          = var.tags

  private_service_connection {
    name                           = "${var.name}-${each.value}-psc"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.value]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = lookup(var.private_dns_zone_ids, each.value, null) == null ? [] : [1]
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_ids[each.value]]
    }
  }

  lifecycle {
    precondition {
      condition     = var.private_endpoint_subnet_id != null
      error_message = "private_endpoint_subnet_id is required when private_endpoints is set."
    }
  }
}

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = each.value.container == null ? azurerm_storage_account.this.id : "${azurerm_storage_account.this.id}/blobServices/default/containers/${each.value.container}"
  role_definition_name = each.value.role
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
  description          = "${each.value.role} for ${each.key}"

  depends_on = [azurerm_storage_container.this]
}

output "id" {
  value = azurerm_storage_account.this.id
}

output "name" {
  value = azurerm_storage_account.this.name
}

output "endpoints" {
  value = {
    blob  = azurerm_storage_account.this.primary_blob_endpoint
    queue = azurerm_storage_account.this.primary_queue_endpoint
    table = azurerm_storage_account.this.primary_table_endpoint
    file  = azurerm_storage_account.this.primary_file_endpoint
  }
}

output "containers" {
  value = { for k, c in azurerm_storage_container.this : k => { name = c.name, url = "${azurerm_storage_account.this.primary_blob_endpoint}${c.name}" } }
}

output "private_endpoint_ids" {
  value = { for k, p in azurerm_private_endpoint.this : k => p.id }
}
