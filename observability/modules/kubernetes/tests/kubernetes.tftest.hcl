mock_provider "helm" {
  override_during = plan
}
mock_provider "kubernetes" {
  override_during = plan
}

variables {
  cluster_name = "aks-eh-dev"
  datadog      = { site = "datadoghq.eu", env = "dev", extra_tags = { team = "platform" } }
  dsv = {
    api_key_ref        = "dsv://eh/dev/datadog-api-key#value"
    tenant             = "contoso"
    fetch_image        = "ehacr.azurecr.io/dsv-fetch@sha256:3333333333333333333333333333333333333333333333333333333333333333"
    identity_client_id = "66666666-6666-6666-6666-666666666666"
  }
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
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.apiKey == "ENC[dsv://eh/dev/datadog-api-key#value]" && yamldecode(helm_release.datadog.values[0]).datadog.secretBackend.command == "/opt/dsv-fetch/dsv-fetch" && yamldecode(helm_release.datadog.values[0]).datadog.secretBackend.arguments == "agent-backend"
    error_message = "Agents resolve the API key ENC[dsv://] reference with dsv-fetch agent-backend; values hold only the reference."
  }
  assert {
    condition = (yamldecode(helm_release.datadog.values[0]).agents.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666"
      && yamldecode(helm_release.datadog.values[0]).agents.additionalLabels["azure.workload.identity/use"] == "true"
      && yamldecode(helm_release.datadog.values[0]).agents.volumes[0].configMap.defaultMode == 320
    && yamldecode(helm_release.datadog.values[0]).clusterChecksRunner.volumeMounts[0].mountPath == "/opt/dsv-fetch")
    error_message = "Workload identity on the agent service account; backend script mounted 0500 in agents and runners."
  }
  assert {
    condition     = strcontains(kubernetes_config_map_v1.dsv_fetch[0].data["dsv-fetch"], "def cmd_agent_backend") && anytrue([for e in yamldecode(helm_release.datadog.values[0]).datadog.env : e.name == "DSV_BASE_URL" && e.value == "https://contoso.secretsvaultcloud.com/v1"])
    error_message = "dsv-fetch script ConfigMap + DSV env for the Agents."
  }
  assert {
    condition = (yamldecode(helm_release.fluent_bit.values[0]).initContainers[0].name == "dsv-fetch"
      && contains(yamldecode(helm_release.fluent_bit.values[0]).initContainers[0].args, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value")
      && yamldecode(helm_release.fluent_bit.values[0]).extraVolumes[1].emptyDir.medium == "Memory"
      && yamldecode(helm_release.fluent_bit.values[0]).podLabels["azure.workload.identity/use"] == "true"
    && !anytrue([for e in yamldecode(helm_release.fluent_bit.values[0]).env : e.name == "DD_API_KEY"]))
    error_message = "Fluent Bit: dsv-fetch init container writes the env-yaml into an in-memory emptyDir; no API key env."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.datadog.values[0]).clusterAgent.confd["postgres.yaml"], "dbm: true") && yamldecode(helm_release.datadog.values[0]).clusterChecksRunner.enabled
    error_message = "DBM cluster checks dispatched to runners."
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
    api_key  = { mode = "existing", secret_name = "dd-from-dsv-syncer" }
    features = { kubelet_tls_mode = "aks_hostca" }
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.apiKeyExistingSecret == "dd-from-dsv-syncer" && !can(yamldecode(helm_release.datadog.values[0]).datadog.secretBackend) && yamldecode(helm_release.datadog.values[0]).datadog.kubelet.hostCAPath == "/etc/kubernetes/certs/kubeletserver.crt"
    error_message = "Fallback: Secret synced by the Delinea dsv-k8s syncer + AKS kubelet CA path."
  }
  assert {
    condition     = length(kubernetes_config_map_v1.fluent_bit_env_placeholder) == 1 && anytrue([for e in yamldecode(helm_release.fluent_bit.values[0]).env : e.name == "DD_API_KEY"]) && length(yamldecode(helm_release.fluent_bit.values[0]).initContainers) == 0
    error_message = "Fallback Fluent Bit: key from the synced Secret, placeholder env include."
  }
}

run "cluster_agent_syncer_secret" {
  command = plan
  variables {
    api_key = { cluster_agent_secret_name = "datadog-cluster-agent-api-key" }
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).clusterAgent.env[0].valueFrom.secretKeyRef.name == "datadog-cluster-agent-api-key"
    error_message = "The Cluster Agent (no Python) can take its key from a syncer-managed Secret."
  }
}

run "reject_dsv_mode_without_identity" {
  command = plan
  variables {
    dsv = { api_key_ref = "dsv://eh/dev/datadog-api-key#value", tenant = "contoso", fetch_image = "ehacr.azurecr.io/dsv-fetch@sha256:3333333333333333333333333333333333333333333333333333333333333333" }
  }
  expect_failures = [helm_release.datadog, helm_release.fluent_bit]
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
