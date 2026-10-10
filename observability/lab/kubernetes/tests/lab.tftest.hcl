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
  obs_telemetry_transport = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
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
  platform_aks = {
    resource_group_name = "eh-rg-aks-dev-sec"
    cluster_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec"
    cluster_name        = "eh-aks-dev-sec"
    oidc_issuer_url     = "https://swedencentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
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
  assert {
    condition     = length(azurerm_federated_identity_credential.collector) == 3 && azurerm_federated_identity_credential.collector["fluent-bit"].subject == "system:serviceaccount:fluent-bit:fluent-bit" && azurerm_federated_identity_credential.collector["datadog-agent"].subject == "system:serviceaccount:datadog:datadog"
    error_message = "Workload identity federation for the Agent, cluster-checks runner and Fluent Bit service accounts."
  }
  assert {
    condition     = yamldecode(module.kubernetes.datadog_values).datadog.apiKey == "ENC[dsv://eh/dev/datadog-api-key#value]" && yamldecode(module.kubernetes.fluent_bit_values).initContainers[0].image == "ehacrdev.azurecr.io/dsv-fetch@sha256:4444444444444444444444444444444444444444444444444444444444444444"
    error_message = "DSV reference; dsv-fetch image from this root's artifacts (img-dsv-fetch); no API key input exists."
  }
}

run "syncer_fallback" {
  command = plan
  variables {
    settings = { api_key_mode = "existing" }
  }
  assert {
    condition     = length(azurerm_federated_identity_credential.collector) == 0 && yamldecode(module.kubernetes.datadog_values).datadog.apiKeyExistingSecret == "datadog-api-key"
    error_message = "Fallback: Secret maintained by the Delinea dsv-k8s syncer; no workload identity needed."
  }
}

run "reject_bad_kubelogin_mode" {
  command = plan
  variables {
    settings = { kubelogin_mode = "devicecode" }
  }
  expect_failures = [var.settings]
}

run "fleet_from_transport_contract" {
  command = plan
  variables {
    obs_telemetry_transport = {
      datadog_site = "datadoghq.com"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets      = { tenant = "contoso", tld = "com", base_url = "https://contoso.secretsvaultcloud.com/v1" }
      aggregator   = { kind = "observability_pipelines", fqdn = "eh-obs-dev-opw.internal.example.io", agent_logs_url = "http://eh-obs-dev-opw.internal.example.io:8282" }
      env          = { fleet = { EH_LOG_PIPELINE = "observability_pipelines", EH_APM_MODE = "datadog", EH_PROFILING_ENABLED = "true" } }
    }
  }
  assert {
    condition     = anytrue([for e in yamldecode(module.kubernetes.datadog_values).datadog.env : e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL" && e.value == "http://eh-obs-dev-opw.internal.example.io:8282"])
    error_message = "Package 3.0.0 transport: the node Agents send logs to the OP Worker of the contract."
  }
  assert {
    condition     = yamldecode(module.kubernetes.datadog_values).datadog.apm.instrumentation.enabled && yamldecode(module.kubernetes.datadog_values).datadog.apm.instrumentation.targets[0].namespaceSelector.matchNames[0] == "hello" && output.contract.log_collector == "datadog-agent"
    error_message = "Single Step Instrumentation of the hello namespace; the Agent collects the logs."
  }
}

run "transport_2x_contract_keeps_fluent_bit" {
  command = plan
  assert {
    condition     = output.contract.log_collector != "datadog-agent" && !try(yamldecode(module.kubernetes.datadog_values).datadog.apm.instrumentation.enabled, false)
    error_message = "Without env.fleet in the contract the root stays on Fluent Bit + OpenTelemetry (2.x path)."
  }
}
