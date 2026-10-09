output "contract" {
  description = "platform-batch contract v1 (catalog/contracts/platform-batch.v1.schema.json). No account keys."
  value = {
    resource_group_name = azurerm_resource_group.this.name
    location            = local.location
    account_id          = azurerm_batch_account.this.id
    account_name        = azurerm_batch_account.this.name
    account_endpoint    = "https://${azurerm_batch_account.this.account_endpoint}"
    private             = local.private
    pool = {
      id                  = azurerm_batch_pool.this.id
      name                = azurerm_batch_pool.this.name
      vm_size             = local.pool.vm_size
      os_type             = "Linux"
      node_agent_sku_id   = local.pool.node_agent_sku_id
      max_dedicated_nodes = local.pool.max_dedicated_nodes
      python              = "python${local.pool.python_version}"
      subnet_id           = local.subnets["batch"].id
    }
    identity = {
      key          = var.settings.identity
      id           = local.identity.id
      client_id    = local.identity.client_id
      principal_id = local.identity.principal_id
    }
    auto_storage = {
      id                 = module.auto_storage.id
      name               = module.auto_storage.name
      blob_endpoint      = module.auto_storage.endpoints.blob
      packages_container = "jobs-packages"
      output_container   = "jobs-output"
    }
    acr_login_server = var.platform_shared.acr_login_server
  }
}
