mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec/providers/Microsoft.ContainerService/managedClusters/eh-aks-aks-dev-sec"
      oidc_issuer_url        = "https://swedencentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
      node_resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec-nodes"
      private_fqdn           = "eh-aks-aks-dev-sec-abc.privatelink.swedencentral.azmk8s.io"
    }
  }
}

# BEGIN FIXTURE (generated): upstream contract shapes with valid Azure IDs.
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
  foundation_network = {
    resource_group_name = "rg-net"
    location            = "swedencentral"
    spoke_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    subnets = {
      "compute"            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-compute", name = "snet-compute", address_prefix = "10.41.0.0/24" }
      "aks-nodes"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aks-nodes", name = "snet-aks-nodes", address_prefix = "10.41.1.0/24" }
      "aca-infra"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca-infra", name = "snet-aca-infra", address_prefix = "10.41.2.0/24" }
      "appsvc-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration", name = "snet-appsvc-integration", address_prefix = "10.41.3.0/24" }
      "flex-integration"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration", name = "snet-flex-integration", address_prefix = "10.41.4.0/24" }
      "aci"                = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aci", name = "snet-aci", address_prefix = "10.41.5.0/24" }
      "private-endpoints"  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-private-endpoints", name = "snet-private-endpoints", address_prefix = "10.41.6.0/24" }
      "postgres"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-postgres", name = "snet-postgres", address_prefix = "10.41.7.0/24" }
      "mysql"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-mysql", name = "snet-mysql", address_prefix = "10.41.8.0/24" }
      "sqlmi"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sqlmi", name = "snet-sqlmi", address_prefix = "10.41.9.0/24" }
      "cassandra-mi"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-cassandra-mi", name = "snet-cassandra-mi", address_prefix = "10.41.10.0/24" }
      "batch"              = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-batch", name = "snet-batch", address_prefix = "10.41.11.0/24" }
      "deploy-agents"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-deploy-agents", name = "snet-deploy-agents", address_prefix = "10.41.12.0/24" }
      "observability"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-observability", name = "snet-observability", address_prefix = "10.41.13.0/24" }
      "sfmc"               = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sfmc", name = "snet-sfmc", address_prefix = "10.41.14.0/24" }
      "aro-master"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-master", name = "snet-aro-master", address_prefix = "10.41.15.0/24" }
      "aro-worker"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-worker", name = "snet-aro-worker", address_prefix = "10.41.16.0/24" }
    }
    egress = { type = "nat-gateway", public_ips = ["20.0.0.1"] }
  }
  foundation_identity = {
    identities = {
      "hello-bff"           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-bff", principal_id = "00000000-0000-0000-0001-000000000000", client_id = "00000000-0000-0000-0002-000000000000", name = "id-hello-bff" }
      "hello-orders-api"    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-orders-api", principal_id = "00000000-0000-0000-0001-000000000001", client_id = "00000000-0000-0000-0002-000000000001", name = "id-hello-orders-api" }
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api", principal_id = "00000000-0000-0000-0001-000000000002", client_id = "00000000-0000-0000-0002-000000000002", name = "id-hello-inventory-api" }
      "hello-catalog-api"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api", principal_id = "00000000-0000-0000-0001-000000000003", client_id = "00000000-0000-0000-0002-000000000003", name = "id-hello-catalog-api" }
      "hello-dbadapter"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter", principal_id = "00000000-0000-0000-0001-000000000004", client_id = "00000000-0000-0000-0002-000000000004", name = "id-hello-dbadapter" }
      "hello-worker"        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker", principal_id = "00000000-0000-0000-0001-000000000005", client_id = "00000000-0000-0000-0002-000000000005", name = "id-hello-worker" }
      "hello-durable"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-durable", principal_id = "00000000-0000-0000-0001-000000000006", client_id = "00000000-0000-0000-0002-000000000006", name = "id-hello-durable" }
      "hello-functions"     = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-functions", principal_id = "00000000-0000-0000-0001-000000000007", client_id = "00000000-0000-0000-0002-000000000007", name = "id-hello-functions" }
      "hello-jobs"          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs", principal_id = "00000000-0000-0000-0001-000000000008", client_id = "00000000-0000-0000-0002-000000000008", name = "id-hello-jobs" }
      "hello-partner-sim"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-partner-sim", principal_id = "00000000-0000-0000-0001-000000000009", client_id = "00000000-0000-0000-0002-000000000009", name = "id-hello-partner-sim" }
      "hello-traffic"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-traffic", principal_id = "00000000-0000-0000-0001-000000000010", client_id = "00000000-0000-0000-0002-000000000010", name = "id-hello-traffic" }
      "hello-frontend"      = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-frontend", principal_id = "00000000-0000-0000-0001-000000000011", client_id = "00000000-0000-0000-0002-000000000011", name = "id-hello-frontend" }
      "obs-collector"       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector", principal_id = "00000000-0000-0000-0001-000000000012", client_id = "00000000-0000-0000-0002-000000000012", name = "id-obs-collector" }
      "obs-dbm"             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-dbm", principal_id = "00000000-0000-0000-0001-000000000013", client_id = "00000000-0000-0000-0002-000000000013", name = "id-obs-dbm" }
      "aks-control-plane"   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-control-plane", principal_id = "00000000-0000-0000-0001-000000000014", client_id = "00000000-0000-0000-0002-000000000014", name = "id-aks-control-plane" }
      "aks-kubelet"         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-kubelet", principal_id = "00000000-0000-0000-0001-000000000015", client_id = "00000000-0000-0000-0002-000000000015", name = "id-aks-kubelet" }
      "deploy-agent"        = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-deploy-agent", principal_id = "00000000-0000-0000-0001-000000000016", client_id = "00000000-0000-0000-0002-000000000016", name = "id-deploy-agent" }
    }
  }
  platform_shared = {
    acr_id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/crshared"
    acr_login_server           = "crshared.azurecr.io"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.OperationalInsights/workspaces/log-shared"
  }
}
# END FIXTURE

run "secure_defaults" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled == true
    error_message = "local accounts must be disabled."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.oidc_issuer_enabled && azurerm_kubernetes_cluster.this.workload_identity_enabled
    error_message = "OIDC issuer and workload identity must be enabled."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled == true
    error_message = "Azure RBAC for Kubernetes authorization must be enabled."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.private_cluster_enabled == true
    error_message = "private API server by default."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay" && azurerm_kubernetes_cluster.this.network_profile[0].network_plugin == "azure"
    error_message = "Azure CNI overlay."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "userAssignedNATGateway"
    error_message = "NAT gateway egress maps to userAssignedNATGateway."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.automatic_upgrade_channel == "patch" && azurerm_kubernetes_cluster.this.node_os_upgrade_channel == "NodeImage"
    error_message = "patch auto-upgrade + NodeImage OS channel."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vm_size == "Standard_D2s_v5" && azurerm_kubernetes_cluster.this.default_node_pool[0].min_count == 1 && azurerm_kubernetes_cluster.this.default_node_pool[0].max_count == 2
    error_message = "system pool 1-2 x Standard_D2s_v5."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].node_public_ip_enabled == false
    error_message = "no node public IPs."
  }
  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.user) == 0 && azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled == false
    error_message = "without a user pool, workloads schedule on the system pool."
  }
  assert {
    condition     = toset(keys(azurerm_federated_identity_credential.workload)) == toset(["hello-bff", "hello-orders-api", "hello-catalog-api", "hello-worker"])
    error_message = "federated credentials for the AKS workloads + Datadog agent."
  }
  assert {
    condition     = azurerm_federated_identity_credential.workload["hello-bff"].subject == "system:serviceaccount:hello:hello-bff"
    error_message = "federated subject must be the service account."
  }
  assert {
    condition     = azurerm_role_assignment.cluster_admin["deploy-agent"].role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin"
    error_message = "deploy-agent gets RBAC cluster admin (no local kubeconfig)."
  }
  assert {
    condition     = output.contract.oidc_issuer_url != "" && output.contract.access.local_accounts == false && can(regex("^/subscriptions/", output.contract.cluster_id))
    error_message = "contract exposes issuer, access info and cluster id."
  }
}

run "firewall_egress_and_user_pool" {
  command = plan
  variables {
    settings = {
      user_pool = { enabled = true, max_count = 3 }
    }
    foundation_network = {
      resource_group_name = "rg-net"
      location            = "swedencentral"
      spoke_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
      subnets = {
        "aks-nodes" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aks-nodes", name = "snet-aks-nodes", address_prefix = "10.41.16.0/22" }
      }
      egress = { type = "firewall", firewall_private_ip = "10.40.1.4" }
    }
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "userDefinedRouting"
    error_message = "firewall egress maps to userDefinedRouting."
  }
  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.user) == 1 && azurerm_kubernetes_cluster_node_pool.user[0].max_count == 3
    error_message = "user pool honours the ceiling."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled == true
    error_message = "system pool is tainted for critical add-ons when a user pool exists."
  }
}

run "public_api_requires_authorized_ranges" {
  command = plan
  variables {
    settings = { private_cluster_enabled = false }
  }
  expect_failures = [var.settings]
}

run "public_api_with_ranges" {
  command = plan
  variables {
    settings = { private_cluster_enabled = false, authorized_ip_ranges = ["203.0.113.10/32"] }
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.api_server_access_profile[0].authorized_ip_ranges == toset(["203.0.113.10/32"])
    error_message = "authorized ranges applied."
  }
}
