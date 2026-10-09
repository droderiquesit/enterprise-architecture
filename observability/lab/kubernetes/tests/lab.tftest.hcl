mock_provider "azurerm" {
  override_during = plan
  mock_data "azurerm_kubernetes_cluster" {
    defaults = {
      kube_config = [{
        host                   = "https://eh-aks-dev-sec-abcd.privatelink.swedencentral.azmk8s.io:443"
        cluster_ca_certificate = "bW9jay1jYQ=="
        client_certificate     = ""
        client_key             = ""
        username               = "clusterUser"
        password               = ""
      }]
    }
  }
}
mock_provider "helm" {
  override_during = plan
}
mock_provider "kubernetes" {
  override_during = plan
}

variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  obs_telemetry_transport = { datadog_site = "datadoghq.com" }
  foundation_identity     = { key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/eh-kv-ident-dev-abcde" }
  platform_aks = {
    resource_group_name = "eh-rg-aks-dev-sec"
    cluster_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec"
    cluster_name        = "eh-aks-dev-sec"
    access              = { private_cluster = true }
  }
}

run "lab_kubernetes" {
  command = plan
  assert {
    condition     = output.contract.cluster_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec" && output.contract.agent.otlp_grpc_port == 4317
    error_message = "obs-kubernetes contract with cluster id."
  }
  assert {
    condition     = local.kubelogin_args[0] == "get-token" && contains(local.kubelogin_args, "6dae42f8-4368-4678-94ff-3960e28e3630")
    error_message = "kubelogin exec with the AKS Entra server app id."
  }
  assert {
    condition     = yamldecode(module.kubernetes.datadog_values).datadog.tags[0] == "application:enterprise-hello"
    error_message = "Lab tags reach the Agent."
  }
}

run "reject_bad_kubelogin_mode" {
  command = plan
  variables {
    settings = { kubelogin_mode = "devicecode" }
  }
  expect_failures = [var.settings]
}
