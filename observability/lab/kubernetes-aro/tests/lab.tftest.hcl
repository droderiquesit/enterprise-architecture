mock_provider "azurerm" {
  override_during = plan
}
mock_provider "helm" {
  override_during = plan
}
mock_provider "kubernetes" {
  override_during = plan
}

# Mock providers cannot open ephemeral resources (Terraform 1.16: "No ephemeral resource types in mock providers") and
# azapi is therefore NOT mocked (it is never called: its only object is the ephemeral resource, count 0 here), so
# the plans run with settings.kube_auth = kubeconfig; the default admin_kubeconfig path (ephemeral azapi
# listAdminCredentials) is covered by terraform validate only.
variables {
  settings = { kube_auth = "kubeconfig", kubeconfig_path = "/tmp/aro-kubeconfig" }
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
  obs_telemetry_transport = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    aggregator   = { kind = "observability_pipelines", agent_logs_url = "http://eh-obs-dev-opw.internal.example.azurecontainerapps.io:8282" }
    env          = { fleet = { EH_LOG_PIPELINE = "observability_pipelines", EH_APM_MODE = "datadog", EH_PROFILING_ENABLED = "true" } }
    secrets = {
      tenant      = "contoso"
      tld         = "com"
      base_url    = "https://contoso.secretsvaultcloud.com/v1"
      fetch_image = "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  }
  artifacts = {
    "img-dsv-fetch" = { image = "ehacrdev.azurecr.io/dsv-fetch@sha256:4444444444444444444444444444444444444444444444444444444444444444" }
  }
  foundation_identity = {
    identities = {
      "obs-collector" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-collector-dev-sec", principal_id = "11111111-1111-1111-1111-111111111111", client_id = "22222222-2222-2222-2222-222222222222", name = "eh-id-obs-collector-dev-sec" }
    }
  }
  platform_aro = {
    enabled         = true
    cluster_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aro-dev-sec/providers/Microsoft.RedHatOpenShift/openShiftClusters/eh-aro-aro-dev-sec"
    cluster_name    = "eh-aro-aro-dev-sec"
    api_server_url  = "https://api.ehdevabcde.swedencentral.aroapp.io:6443"
    oidc_issuer_url = "https://swedencentral.oic.aro.azure.net/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111"
  }
}

run "lab_aro" {
  command = plan
  assert {
    condition     = output.contract.enabled && output.contract.distribution == "openshift" && output.contract.cluster_id == var.platform_aro.cluster_id && output.contract.agent.otlp_grpc_port == 4317 && output.contract.log_collector == "datadog-agent"
    error_message = "obs-kubernetes-aro contract: openshift distribution, cluster id, node Agent log collector."
  }
  assert {
    condition = (length(azurerm_federated_identity_credential.collector) == 3
      && alltrue([for k, f in azurerm_federated_identity_credential.collector : f.issuer == var.platform_aro.oidc_issuer_url && tolist(f.audience) == tolist(["api://AzureADTokenExchange"]) && f.user_assigned_identity_id == var.foundation_identity.identities["obs-collector"].id])
      && azurerm_federated_identity_credential.collector["datadog-agent"].subject == "system:serviceaccount:datadog:datadog"
      && azurerm_federated_identity_credential.collector["datadog-cluster-agent"].subject == "system:serviceaccount:datadog:datadog-cluster-agent"
    && azurerm_federated_identity_credential.collector["datadog-cluster-checks"].subject == "system:serviceaccount:datadog:datadog-cluster-checks")
    error_message = "Entra workload identity: obs-collector federated with the ARO managed OIDC issuer for the node Agent, Cluster Agent and runner service accounts (no Fluent Bit)."
  }
  assert {
    condition = (length(module.kubernetes[0].datadog_values) == 3
      && yamldecode(module.kubernetes[0].datadog_values[2]).agents.podSecurity.securityContextConstraints.create
      && yamldecode(module.kubernetes[0].datadog_values[1]).datadog.apiKey == "ENC[dsv://eh/dev/datadog-api-key#value]"
      && yamldecode(module.kubernetes[0].datadog_values[1]).agents.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "22222222-2222-2222-2222-222222222222"
    && module.kubernetes[0].datadog_postrender_args[2] == "ehacrdev.azurecr.io/dsv-fetch@sha256:4444444444444444444444444444444444444444444444444444444444444444")
    error_message = "OpenShift values layer, DSV reference only, workload identity client id, dsv-fetch image from img-dsv-fetch."
  }
  assert {
    condition = (yamldecode(module.kubernetes[0].datadog_values[1]).datadog.apm.instrumentation.enabled
      && strcontains(yamldecode(module.kubernetes[0].datadog_values[1]).datadog.containerExcludeLogs, "kube_namespace:^openshift-")
    && anytrue([for e in yamldecode(module.kubernetes[0].datadog_values[1]).datadog.env : e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL" && e.value == "http://eh-obs-dev-opw.internal.example.azurecontainerapps.io:8282"]))
    error_message = "SSI on the hello namespace, OpenShift platform namespaces excluded from log collection, Agent logs -> OP Worker."
  }
  assert {
    condition     = local.kube_path == "/tmp/aro-kubeconfig" && local.kube_host == null && length(ephemeral.azapi_resource_action.admin_kubeconfig) == 0
    error_message = "kube_auth = kubeconfig: providers read the prepared kubeconfig, no admin credentials are requested."
  }
}

run "blocked_platform_creates_nothing" {
  command = plan
  variables {
    platform_aro = { enabled = false }
  }
  assert {
    condition     = length(module.kubernetes) == 0 && length(azurerm_federated_identity_credential.collector) == 0 && !output.contract.enabled && output.contract.status == "blocked"
    error_message = "platform-aro blocked/disabled -> no release, no federation, blocked contract."
  }
}

run "no_runner_no_runner_federation" {
  command = plan
  variables {
    settings = { kube_auth = "kubeconfig", kubeconfig_path = "/tmp/aro-kubeconfig", cluster_checks_runner = false }
  }
  assert {
    condition     = length(azurerm_federated_identity_credential.collector) == 2 && module.kubernetes[0].datadog_postrender_args[4] == "2"
    error_message = "Without cluster-checks runners only the Agent and Cluster Agent service accounts are federated."
  }
}

run "reject_cluster_without_oidc_issuer" {
  command = plan
  variables {
    platform_aro = {
      enabled        = true
      cluster_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aro-dev-sec/providers/Microsoft.RedHatOpenShift/openShiftClusters/eh-aro-aro-dev-sec"
      cluster_name   = "eh-aro-aro-dev-sec"
      api_server_url = "https://api.ehdevabcde.swedencentral.aroapp.io:6443"
    }
  }
  expect_failures = [azurerm_federated_identity_credential.collector]
}
# fluent_bit_direct / the in-cluster OP Worker on OpenShift: rejected by modules/kubernetes (its tests).

run "reject_kubeconfig_mode_without_path" {
  command = plan
  variables {
    settings = { kube_auth = "kubeconfig" }
  }
  expect_failures = [var.settings]
}
