mock_provider "helm" {
  override_during = plan
}
mock_provider "kubernetes" {
  override_during = plan
}

variables {
  cluster_name = "aks-eh-dev"
  datadog      = { site = "datadoghq.eu", env = "dev", extra_tags = { team = "platform" } }
  api_key_wo   = "mock-not-a-real-key"
  cluster_checks = {
    "postgres.yaml" = "cluster_check: true\ninit_config: {}\ninstances:\n  - host: psql-eh-dev.postgres.database.azure.com\n    dbm: true\n"
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = helm_release.datadog.version == "3.253.2" && helm_release.fluent_bit.version == "0.58.3"
    error_message = "Charts pinned."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.logs.enabled == false && yamldecode(helm_release.datadog.values[0]).datadog.logs.containerCollectAll == false
    error_message = "Agent container log collection must be disabled (Fluent Bit owns app logs)."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.otlp.receiver.protocols.grpc.useHostPort && yamldecode(helm_release.datadog.values[0]).datadog.otlp.receiver.protocols.grpc.endpoint == "0.0.0.0:4317"
    error_message = "OTLP gRPC on hostPort 4317."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).providers.aks.enabled && !can(yamldecode(helm_release.datadog.values[0]).datadog.kubelet.tlsVerify)
    error_message = "AKS provider on; TLS verification kept by default."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.apiKeyExistingSecret == "datadog-api-key" && !strcontains(helm_release.datadog.values[0], "mock-not-a-real-key")
    error_message = "API key only via an existing Secret, never in values."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.datadog.values[0]).clusterAgent.confd["postgres.yaml"], "dbm: true") && yamldecode(helm_release.datadog.values[0]).clusterChecksRunner.enabled
    error_message = "DBM cluster checks dispatched to runners."
  }
  assert {
    condition     = length(kubernetes_secret_v1.api_key) == 2 && kubernetes_secret_v1.api_key["datadog"].data_wo_revision == 1
    error_message = "Write-only API key secret in both namespaces."
  }
  assert {
    condition     = strcontains(kubernetes_config_map_v1.fluent_bit.data["fluent-bit.yaml"], "/var/log/containers/*.log") && contains(yamldecode(helm_release.fluent_bit.values[0]).args, "--config=/fluent-bit/etc/eh/fluent-bit.yaml")
    error_message = "Fluent Bit DaemonSet runs the validated k8s config."
  }
  assert {
    condition     = yamldecode(helm_release.fluent_bit.values[0]).resources.limits.memory == "512Mi" && yamldecode(helm_release.datadog.values[0]).agents.containers.agent.resources.limits.memory == "512Mi"
    error_message = "Bounded resources."
  }
  assert {
    condition     = output.contract.agent.otlp_grpc_port == 4317 && output.contract.log_route == "daemonset" && output.contract.agent.local_service == "datadog.datadog.svc.cluster.local"
    error_message = "obs-kubernetes contract."
  }
}

run "hostca_and_existing_secret" {
  command = plan
  variables {
    api_key_wo = null
    api_key    = { mode = "existing", secret_name = "dd-from-csi" }
    features   = { kubelet_tls_mode = "aks_hostca" }
  }
  assert {
    condition     = length(kubernetes_secret_v1.api_key) == 0 && yamldecode(helm_release.datadog.values[0]).datadog.kubelet.hostCAPath == "/etc/kubernetes/certs/kubeletserver.crt"
    error_message = "Existing secret + AKS kubelet CA path."
  }
}

run "reject_write_only_without_key" {
  command = plan
  variables {
    api_key_wo = null
  }
  expect_failures = [kubernetes_secret_v1.api_key]
}

run "reject_unpinned_chart" {
  command = plan
  variables {
    charts = { datadog_version = "latest" }
  }
  expect_failures = [var.charts]
}

run "reject_bad_kubelet_mode" {
  command = plan
  variables {
    features = { kubelet_tls_mode = "whatever" }
  }
  expect_failures = [var.features]
}
