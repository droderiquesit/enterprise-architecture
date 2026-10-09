# Shared Cosmos DB account module for the five Cosmos API roots (platform/data/cosmos-*).
# Code reuse only: each root owns its account (ADR-0001 §3 rule 1).
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.9" }
  }
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$", var.name))
    error_message = "Cosmos DB account names are 3-44 lowercase alphanumerics or hyphens."
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

variable "api" {
  type        = string
  description = "nosql | mongo | cassandra | gremlin | table"
  validation {
    condition     = contains(["nosql", "mongo", "cassandra", "gremlin", "table"], var.api)
    error_message = "api must be one of nosql, mongo, cassandra, gremlin, table."
  }
}

variable "capacity_mode" {
  type        = string
  default     = "serverless"
  description = "serverless | provisioned. Serverless is single-region and cannot use free tier."
  validation {
    condition     = contains(["serverless", "provisioned"], var.capacity_mode)
    error_message = "capacity_mode must be serverless or provisioned."
  }
}

variable "free_tier_enabled" {
  type    = bool
  default = false
}

variable "local_authentication_enabled" {
  type        = bool
  default     = false
  description = "Keys/connection strings. Disabled for APIs with Entra data-plane RBAC (NoSQL, Table)."
}

variable "backup_type" {
  type        = string
  default     = "Continuous"
  description = "Continuous (7-day tier) or Periodic. Cassandra does not support continuous backup."
  validation {
    condition     = contains(["Continuous", "Periodic"], var.backup_type)
    error_message = "backup_type must be Continuous or Periodic."
  }
}

variable "mongo_server_version" {
  type    = string
  default = null
}

variable "consistency_level" {
  type    = string
  default = "Session"
}

variable "private_endpoint" {
  type = object({
    enabled             = bool
    subnet_id           = optional(string)
    private_dns_zone_id = optional(string)
    name                = optional(string)
  })
}

locals {
  kind = var.api == "mongo" ? "MongoDB" : "GlobalDocumentDB"

  api_capability = {
    nosql     = []
    mongo     = ["EnableMongo"]
    cassandra = ["EnableCassandra"]
    gremlin   = ["EnableGremlin"]
    table     = ["EnableTable"]
  }[var.api]

  capabilities = concat(local.api_capability, var.capacity_mode == "serverless" ? ["EnableServerless"] : [])

  # Private Link group IDs per API (https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints).
  pe_group_id = {
    nosql     = "Sql"
    mongo     = "MongoDB"
    cassandra = "Cassandra"
    gremlin   = "Gremlin"
    table     = "Table"
  }[var.api]

  endpoints = {
    nosql     = { endpoint = "https://${var.name}.documents.azure.com:443/", host = "${var.name}.documents.azure.com", port = 443 }
    mongo     = { endpoint = "mongodb://${var.name}.mongo.cosmos.azure.com:10255/?ssl=true&replicaSet=globaldb&retrywrites=false", host = "${var.name}.mongo.cosmos.azure.com", port = 10255 }
    cassandra = { endpoint = "${var.name}.cassandra.cosmos.azure.com:10350", host = "${var.name}.cassandra.cosmos.azure.com", port = 10350 }
    gremlin   = { endpoint = "wss://${var.name}.gremlin.cosmos.azure.com:443/", host = "${var.name}.gremlin.cosmos.azure.com", port = 443 }
    table     = { endpoint = "https://${var.name}.table.cosmos.azure.com:443/", host = "${var.name}.table.cosmos.azure.com", port = 443 }
  }[var.api]
}

resource "azurerm_cosmosdb_account" "this" {
  name                                  = var.name
  resource_group_name                   = var.resource_group_name
  location                              = var.location
  offer_type                            = "Standard"
  kind                                  = local.kind
  mongo_server_version                  = var.api == "mongo" ? var.mongo_server_version : null
  free_tier_enabled                     = var.capacity_mode == "serverless" ? false : var.free_tier_enabled
  local_authentication_enabled          = var.local_authentication_enabled
  public_network_access_enabled         = false
  access_key_metadata_writes_enabled    = false
  network_acl_bypass_for_azure_services = false
  automatic_failover_enabled            = false
  multiple_write_locations_enabled      = false
  minimal_tls_version                   = "Tls12"
  tags                                  = var.tags

  consistency_policy {
    consistency_level = var.consistency_level
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }

  dynamic "capabilities" {
    for_each = toset(local.capabilities)
    content {
      name = capabilities.value
    }
  }

  backup {
    type                = var.backup_type
    tier                = var.backup_type == "Continuous" ? "Continuous7Days" : null
    interval_in_minutes = var.backup_type == "Periodic" ? 1440 : null
    retention_in_hours  = var.backup_type == "Periodic" ? 168 : null
    storage_redundancy  = var.backup_type == "Periodic" ? "Local" : null
  }
}

module "private_endpoint" {
  count                = var.private_endpoint.enabled ? 1 : 0
  source               = "../../../foundation/modules/private-endpoint"
  name                 = coalesce(var.private_endpoint.name, "pep-${var.name}")
  resource_group_name  = var.resource_group_name
  location             = var.location
  subnet_id            = var.private_endpoint.subnet_id
  target_resource_id   = azurerm_cosmosdb_account.this.id
  subresource_names    = [local.pe_group_id]
  private_dns_zone_ids = compact([var.private_endpoint.private_dns_zone_id])
  tags                 = var.tags
}

output "id" {
  value = azurerm_cosmosdb_account.this.id
}

output "name" {
  value = azurerm_cosmosdb_account.this.name
}

output "kind" {
  value = local.kind
}

output "capabilities" {
  value = local.capabilities
}

output "document_endpoint" {
  description = "Account (NoSQL/document) endpoint returned by ARM."
  value       = azurerm_cosmosdb_account.this.endpoint
}

output "api_endpoint" {
  value = local.endpoints.endpoint
}

output "api_host" {
  value = local.endpoints.host
}

output "api_port" {
  value = local.endpoints.port
}

output "private_endpoint_group_id" {
  value = local.pe_group_id
}

output "private_endpoint_id" {
  value = try(module.private_endpoint[0].id, null)
}

output "private_ip_address" {
  value = try(module.private_endpoint[0].private_ip_address, null)
}
