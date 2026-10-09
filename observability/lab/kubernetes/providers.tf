provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
  # pipeline identities hold no provider-registration rights (bootstrap registers providers)
  resource_provider_registrations = "none"
}

# Cluster endpoint + CA from the existing cluster (platform-aks owns it). Local accounts are disabled on
# AKS (Entra + Azure RBAC), so credentials come from kubelogin (exec plugin) - nothing cached in state.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.platform_aks.cluster_name
  resource_group_name = var.platform_aks.resource_group_name
}

locals {
  # AKS Entra server application id (well-known, same for every tenant)
  aks_server_app_id = coalesce(try(var.platform_aks.access.entra_server_app_id, null), "6dae42f8-4368-4678-94ff-3960e28e3630")
  kube_host         = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  kube_ca           = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  kubelogin_args = concat(
    ["get-token", "--login", var.settings.kubelogin_mode, "--server-id", local.aks_server_app_id],
    var.settings.kubelogin_mode == "azurecli" ? [] : ["--tenant-id", var.environment.tenant_id],
  )
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = local.kubelogin_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = local.kubelogin_args
    }
  }
}
