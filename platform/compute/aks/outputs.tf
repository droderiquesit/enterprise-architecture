output "contract" {
  description = "platform-aks contract v1 (catalog/contracts/platform-aks.v1.schema.json). No kubeconfig or credentials."
  value = {
    resource_group_name    = azurerm_resource_group.this.name
    location               = local.location
    cluster_id             = azurerm_kubernetes_cluster.this.id
    cluster_name           = azurerm_kubernetes_cluster.this.name
    kubernetes_version     = var.settings.kubernetes_version
    node_resource_group    = azurerm_kubernetes_cluster.this.node_resource_group
    node_resource_group_id = azurerm_kubernetes_cluster.this.node_resource_group_id
    oidc_issuer_url        = azurerm_kubernetes_cluster.this.oidc_issuer_url
    os_type                = "Linux"
    access = {
      # kubeconfig-free access: `az aks get-credentials` + kubelogin (Entra), or `az aks command invoke`.
      private_cluster      = var.settings.private_cluster_enabled
      fqdn                 = azurerm_kubernetes_cluster.this.fqdn
      private_fqdn         = azurerm_kubernetes_cluster.this.private_fqdn
      authorized_ip_ranges = var.settings.private_cluster_enabled ? [] : var.settings.authorized_ip_ranges
      run_command_enabled  = var.settings.run_command_enabled
      local_accounts       = false
      azure_rbac_enabled   = true
      entra_server_app_id  = "6dae42f8-4368-4678-94ff-3960e28e3630" # AKS Entra server (kubelogin --server-id)
    }
    kubelet_identity = {
      id           = local.kubelet.id
      client_id    = local.kubelet.client_id
      principal_id = local.kubelet.principal_id
    }
    key_vault_secrets_provider = var.settings.key_vault_secrets_provider_enabled ? {
      client_id    = try(azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].client_id, null)
      principal_id = try(azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id, null)
    } : null
    network = {
      plugin         = "azure"
      plugin_mode    = "overlay"
      data_plane     = "cilium"
      pod_cidr       = var.settings.pod_cidr
      service_cidr   = var.settings.service_cidr
      outbound_type  = local.outbound_type
      node_subnet_id = local.node_subnet.id
    }
    node_pools = merge(
      { system = { vm_size = var.settings.system_pool.vm_size, min_count = var.settings.system_pool.min_count, max_count = var.settings.system_pool.max_count, mode = "System", os_sku = var.settings.system_pool.os_sku } },
      var.settings.user_pool.enabled ? { user = { vm_size = var.settings.user_pool.vm_size, min_count = var.settings.user_pool.min_count, max_count = var.settings.user_pool.max_count, mode = "User", os_sku = var.settings.user_pool.os_sku } } : {},
    )
    workload_identities = {
      for k, v in local.federated : k => {
        namespace       = v.namespace
        service_account = v.service_account
        client_id       = local.identities[k].client_id
      }
    }
  }
}
