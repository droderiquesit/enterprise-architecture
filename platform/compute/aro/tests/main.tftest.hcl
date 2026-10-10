mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aro-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
      principal_id = "00000000-0000-0000-0003-000000000000"
    }
  }
  mock_resource "azurerm_redhat_openshift_cluster" {
    defaults = {
      id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aro-dev-sec/providers/Microsoft.RedHatOpenShift/openShiftClusters/eh-aro-aro-dev-sec"
      console_url = "https://console-openshift-console.apps.ehdevabcde.swedencentral.aroapp.io/"
    }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_data "azapi_resource" {
    defaults = {
      output = { properties = { clusterProfile = { oidcIssuer = "https://swedencentral.oic.aro.azure.net/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111" } } }
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
  }
  foundation_identity = {
    identities = {
      "hello-catalog-api" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api"
        principal_id = "11111111-1111-1111-1111-000000000003"
        client_id    = "22222222-2222-2222-2222-000000000003"
        name         = "id-hello-catalog-api"
      }
      "obs-collector" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector"
        principal_id = "11111111-1111-1111-1111-000000000013"
        client_id    = "22222222-2222-2222-2222-000000000013"
        name         = "id-obs-collector"
      }
    }
  }
}
# END FIXTURE

run "blocked_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_redhat_openshift_cluster.this) == 0 && output.contract.status == "blocked" && output.contract.oidc_issuer_url == null && length(data.azapi_resource.cluster) == 0 && length(azurerm_federated_identity_credential.workload) == 0 && output.contract.workload_identities == {}
    error_message = "ARO is blocked/disabled by default."
  }
}

run "enabled_managed_identities" {
  command = plan
  variables {
    settings = {
      enabled             = true
      version             = "4.17.27"
      aro_rp_principal_id = "00000000-0000-0000-0004-000000000000"
    }
    pull_secret = "{\"auths\":{}}"
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.operator) == 8 && length(azurerm_role_assignment.cluster_federation) == 8
    error_message = "8 platform workload identities federated by the cluster identity."
  }
  assert {
    condition     = length(azurerm_role_assignment.operator_network) == 11
    error_message = "4 subnet-scoped operators x 2 subnets + 3 VNet-scoped operators."
  }
  assert {
    condition     = azurerm_redhat_openshift_cluster.this[0].api_server_profile[0].visibility == "Private" && azurerm_redhat_openshift_cluster.this[0].ingress_profile[0].visibility == "Private"
    error_message = "private API server and ingress."
  }
  assert {
    condition     = azurerm_redhat_openshift_cluster.this[0].worker_profile[0].node_count == 3 && azurerm_redhat_openshift_cluster.this[0].main_profile[0].vm_size == "Standard_D8s_v5"
    error_message = "minimum ARO topology (44-core quota)."
  }
  assert {
    condition     = azurerm_redhat_openshift_cluster.this[0].cluster_profile[0].pull_secret == "{\"auths\":{}}"
    error_message = "pull secret is the pipeline input (DSV aro-pull-secret)."
  }
  assert {
    condition     = data.azapi_resource.cluster[0].type == "Microsoft.RedHatOpenShift/openShiftClusters@2025-07-25" && contains(data.azapi_resource.cluster[0].response_export_values, "properties.clusterProfile.oidcIssuer")
    error_message = "managed OIDC issuer read (GET) from the ARO resource with azapi (azurerm 5.9 does not expose clusterProfile.oidcIssuer)."
  }
  assert {
    condition = (
      length(azurerm_federated_identity_credential.workload) == 1 && contains(keys(azurerm_federated_identity_credential.workload), "hello-catalog-api") &&
      azurerm_federated_identity_credential.workload["hello-catalog-api"].subject == "system:serviceaccount:hello:hello-catalog-api" &&
      one(azurerm_federated_identity_credential.workload["hello-catalog-api"].audience) == "api://AzureADTokenExchange" &&
      azurerm_federated_identity_credential.workload["hello-catalog-api"].user_assigned_identity_id == var.foundation_identity.identities["hello-catalog-api"].id
    )
    error_message = "hello-catalog-api (foundation-identity) federated (issuer = the azapi-read clusterProfile.oidcIssuer, known after the cluster exists) for system:serviceaccount:hello:hello-catalog-api (app workload identity, as platform-aks on AKS)."
  }
  assert {
    condition     = output.contract.workload_identities["hello-catalog-api"] == { namespace = "hello", service_account = "hello-catalog-api", client_id = "22222222-2222-2222-2222-000000000003" } && length(output.contract.workload_identities) == 1
    error_message = "contract workload_identities: namespace / service account / client id of each federated app identity (obs identities are federated by obs-kubernetes-aro)."
  }
}

run "workload_identity_unknown_key_skipped" {
  command = plan
  variables {
    settings = {
      enabled             = true
      version             = "4.17.27"
      aro_rp_principal_id = "00000000-0000-0000-0004-000000000000"
      workload_identities = { "hello-missing" = { namespace = "hello", service_account = "hello-missing" } }
    }
  }
  assert {
    condition     = length(azurerm_federated_identity_credential.workload) == 0 && output.contract.workload_identities == {}
    error_message = "identity keys missing in foundation-identity are skipped (same filter as platform-aks)."
  }
}

run "enabled_requires_prereqs" {
  command = plan
  variables {
    settings = { enabled = true }
  }
  expect_failures = [var.settings]
}
