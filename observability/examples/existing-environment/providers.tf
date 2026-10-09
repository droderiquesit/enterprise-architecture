# Credentials from DD_API_KEY / DD_APP_KEY (pipeline: Delinea DSV -> masked env, pipelines/templates/dsv-secrets.yml). Never in tfvars.
provider "datadog" {
  api_url = "https://api.${var.datadog_site}/"
}

# Azure: only diagnostic settings (and, when enabled, agent extensions) on EXISTING resources.
provider "azurerm" {
  features {}
  subscription_id     = var.azure_subscription_id
  storage_use_azuread = true
}

# Required by the azure-integration module (native mode only); unused in app_registration mode.
provider "azapi" {
  subscription_id = var.azure_subscription_id
}

# Existing AKS cluster (Entra ID auth via kubelogin). Only the monitoring namespaces are written.
provider "kubernetes" {
  host                   = var.kubernetes.host
  cluster_ca_certificate = base64decode(var.kubernetes.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}

provider "helm" {
  kubernetes = {
    host                   = var.kubernetes.host
    cluster_ca_certificate = base64decode(var.kubernetes.cluster_ca_certificate)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
    }
  }
}
