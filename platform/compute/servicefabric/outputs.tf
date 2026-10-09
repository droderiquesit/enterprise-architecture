output "contract" {
  description = "platform-servicefabric contract v1 (catalog/contracts/platform-servicefabric.v1.schema.json)."
  value = {
    enabled             = local.enabled
    status              = local.enabled ? "implemented" : "disabled"
    resource_group_name = local.enabled ? azurerm_resource_group.this[0].name : null
    cluster_id          = local.enabled ? azurerm_service_fabric_managed_cluster.this[0].id : null
    cluster_name        = local.enabled ? azurerm_service_fabric_managed_cluster.this[0].name : null
    management_endpoint = local.enabled ? "https://${local.names.service_fabric}.${local.location}.cloudapp.azure.com:19080" : null
    client_endpoint     = local.enabled ? "${local.names.service_fabric}.${local.location}.cloudapp.azure.com:19000" : null
    sku                 = var.settings.sku
    os_type             = "Windows"
    node_type           = local.nt.name
    node_count          = local.nt.instance_count
    app_port            = var.settings.app_port
    byo_vnet            = local.byovnet
  }
}
