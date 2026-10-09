# Private endpoint + private DNS zone group for any PaaS resource that supports Private Link.
# The DNS zones themselves are owned by foundation-network and passed in by ID.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.9" }
  }
}

variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "target_resource_id" {
  type = string
}

variable "subresource_names" {
  type        = list(string)
  description = "Private Link group IDs, e.g. [\"sqlServer\"], [\"blob\"], [\"Sql\"] for Cosmos NoSQL."
}

variable "private_dns_zone_ids" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_private_endpoint" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  subnet_id                     = var.subnet_id
  custom_network_interface_name = "${var.name}-nic"
  tags                          = var.tags

  private_service_connection {
    name                           = "${var.name}-psc"
    private_connection_resource_id = var.target_resource_id
    subresource_names              = var.subresource_names
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) > 0 ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }
}

output "id" {
  value = azurerm_private_endpoint.this.id
}

output "private_ip_address" {
  value = try(azurerm_private_endpoint.this.private_service_connection[0].private_ip_address, null)
}
