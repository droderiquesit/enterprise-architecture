output "contract" {
  description = "platform-aro contract v1 (catalog/contracts/platform-aro.v1.schema.json). No kubeadmin credentials."
  value = {
    enabled             = local.enabled
    status              = local.enabled ? "implemented" : "blocked"
    resource_group_name = local.enabled ? azurerm_resource_group.this[0].name : null
    cluster_id          = local.enabled ? azurerm_redhat_openshift_cluster.this[0].id : null
    cluster_name        = local.enabled ? azurerm_redhat_openshift_cluster.this[0].name : null
    console_url         = local.enabled ? azurerm_redhat_openshift_cluster.this[0].console_url : null
    api_server_url      = local.enabled ? azurerm_redhat_openshift_cluster.this[0].api_server_profile[0].url : null
    api_server_ip       = local.enabled ? azurerm_redhat_openshift_cluster.this[0].api_server_profile[0].ip_address : null
    ingress_ip          = local.enabled ? azurerm_redhat_openshift_cluster.this[0].ingress_profile[0].ip_address : null
    # managed OIDC issuer (workload identity for application / observability service accounts); null when disabled
    oidc_issuer_url = local.issuer
    # application identities federated with the issuer (identity key => namespace / service account / client id);
    # {} when disabled. deploy-specialized annotates its service account with client_id (workload identity, DSV reads).
    workload_identities = {
      for k, v in local.federated : k => {
        namespace       = v.namespace
        service_account = v.service_account
        client_id       = local.identities[k].client_id
      }
    }
    version        = var.settings.version
    api_visibility = var.settings.api_visibility
    worker_count   = var.settings.worker_count
    os_type        = "Linux"
  }
}
