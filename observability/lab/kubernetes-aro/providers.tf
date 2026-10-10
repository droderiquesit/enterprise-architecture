provider "azurerm" {
  features {}
  subscription_id     = var.environment.subscription_id
  tenant_id           = var.environment.tenant_id
  storage_use_azuread = true
  # pipeline identities hold no provider-registration rights (bootstrap registers providers)
  resource_provider_registrations = "none"
}

provider "azapi" {
  subscription_id            = var.environment.subscription_id
  tenant_id                  = var.environment.tenant_id
  skip_provider_registration = true # same reason as resource_provider_registrations above
}

# Cluster credentials (README "Provider authentication"): ARO has no Entra / kubelogin path for the Kubernetes API, so
# the helm / kubernetes providers use the cluster's admin kubeconfig from the ARM action listAdminCredentials
# (`az aro get-admin-kubeconfig`), read with an EPHEMERAL azapi resource: the kubeconfig (client certificate + key) is
# opened per run, used only in the provider configuration and never written to the plan or the state. The plan and
# apply identities need Microsoft.RedHatOpenShift/openShiftClusters/listAdminCredentials/action on the cluster.
ephemeral "azapi_resource_action" "admin_kubeconfig" {
  count                  = local.enabled && var.settings.kube_auth == "admin_kubeconfig" ? 1 : 0
  type                   = "Microsoft.RedHatOpenShift/openShiftClusters@2025-07-25"
  resource_id            = var.platform_aro.cluster_id
  action                 = "listAdminCredentials"
  method                 = "POST"
  response_export_values = ["kubeconfig"]
}

locals {
  # ephemeral: the decoded kubeconfig never leaves this run (provider configuration only)
  admin_kubeconfig = try(yamldecode(base64decode(ephemeral.azapi_resource_action.admin_kubeconfig[0].output.kubeconfig)), null)
  kube_user        = try(local.admin_kubeconfig.users[0].user, {})
  kube_cluster     = try(local.admin_kubeconfig.clusters[0].cluster, {})
  # API server from the platform-aro contract (= the kubeconfig's server); CA from the kubeconfig, else the
  # non-secret settings.api_ca_certificate (PEM), else the deploy agent's trust store - never insecure-skip-tls-verify
  kube_file = var.settings.kube_auth == "kubeconfig"
  kube_host = local.kube_file ? null : try(coalesce(var.platform_aro.api_server_url, try(local.kube_cluster.server, null)), null)
  kube_ca   = local.kube_file ? null : try(base64decode(local.kube_cluster["certificate-authority-data"]), var.settings.api_ca_certificate)
  kube_cert = local.kube_file ? null : try(base64decode(local.kube_user["client-certificate-data"]), null)
  kube_key  = local.kube_file ? null : try(base64decode(local.kube_user["client-key-data"]), null)
  kube_path = local.kube_file ? var.settings.kubeconfig_path : null
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_cert
  client_key             = local.kube_key
  config_path            = local.kube_path
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    client_certificate     = local.kube_cert
    client_key             = local.kube_key
    config_path            = local.kube_path
  }
}
