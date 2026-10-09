provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
}

# Cluster endpoint + CA from the cluster resource (listClusterUserCredential; local accounts are disabled, so
# the user kubeconfig carries no credentials). Tokens come from kubelogin (Entra ID):
#   azurecli          - pipeline (AzureCLI task signed in with workload identity federation) or a developer
#   workloadidentity  - agents with AZURE_FEDERATED_TOKEN_FILE/AZURE_CLIENT_ID/AZURE_TENANT_ID set
# The private API server (platform-aks default) is reachable from foundation-deploy-agents in the VNet.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.platform_aks.cluster_name
  resource_group_name = var.platform_aks.resource_group_name
}

locals {
  kube_host = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  kube_ca   = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  kubelogin_args = concat(
    ["get-token", "--login", var.settings.kubelogin_mode, "--server-id", var.platform_aks.access.entra_server_app_id],
    var.settings.kubelogin_mode == "workloadidentity" ? [] : ["--environment", "AzurePublicCloud", "--tenant-id", var.environment.tenant_id],
  )
}

# kubernetes provider: namespace (cluster-scoped prerequisite owned by this root) + LB address lookup.
provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = local.kubelogin_args
  }
}

# helm provider 3.x (Helm v3 SDK): attribute syntax for kubernetes/exec. One release per workload.
# OCI chart source (settings.helm.chart_repository = "oci://<acr>/helm"): the agent runs
# `helm registry login <acr> --username 00000000-0000-0000-0000-000000000000 --password-stdin` with an
# `az acr login --expose-token` token before terraform; the provider reads the default registry config.
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
